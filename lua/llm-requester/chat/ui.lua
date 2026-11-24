-- Chat window rendering and buffer/window lifecycle.
--
-- The module owns only presentation concerns. Session state and request
-- orchestration live in llm-requester.chat.

local api = vim.api
local utils = require('llm-requester.utils')
local Stats = require('llm-requester.chat.stats')

local Ui = {}

local state = {
    config = nil,
    handlers = {},
    prompt_win = nil,
    response_win = nil,
    prompt_buf = nil,
    response_buf = nil,
    speed = nil,
}

local function is_valid_win(win)
    return win ~= nil and api.nvim_win_is_valid(win)
end

local function is_valid_buf(buf)
    return buf ~= nil and api.nvim_buf_is_valid(buf)
end

local function format_usage(usage)
    if not usage or not usage.total_tokens then
        return ''
    end

    return string.format(
        '(total/in/out: %d/%d/%d)',
        usage.total_tokens or 0,
        usage.input or 0,
        usage.output or 0
    )
end

local function mode_of(session)
    return session and session.mode == 'agent' and 'agent' or 'chat'
end

local function set_title(session)
    if not is_valid_win(state.response_win) then
        return
    end

    local parts = {}
    local usage = format_usage(session and session.usage)
    if usage ~= '' then
        table.insert(parts, usage)
    end

    local speed = Stats.format(state.speed)
    if speed ~= '' and (not state.config or state.config.show_speed ~= false) then
        table.insert(parts, '· ' .. speed)
    end

    vim.wo[state.response_win].winbar = string.format(
        ' [%s] Response %s',
        mode_of(session),
        table.concat(parts, ' ')
    )
end

local function close_stale_windows()
    if is_valid_win(state.prompt_win) then
        api.nvim_win_close(state.prompt_win, true)
    end
    if is_valid_win(state.response_win) then
        api.nvim_win_close(state.response_win, true)
    end

    state.prompt_win = nil
    state.response_win = nil
end

-- Window options must be re-applied on every open: scratch buffers are reused
-- after the window is closed, so their window-local options are gone.
local function apply_window_options()
    local config = state.config or {}

    if is_valid_buf(state.prompt_buf) then
        utils.setup_prompt_buffer(state.prompt_buf)
    end

    if is_valid_win(state.prompt_win) then
        vim.wo[state.prompt_win].wrap = config.prompt_wrap ~= false
        vim.wo[state.prompt_win].linebreak = true
    end

    if is_valid_win(state.response_win) then
        local win = state.response_win
        vim.wo[win].wrap = config.response_wrap ~= false
        vim.wo[win].linebreak = true
        vim.wo[win].breakindent = true

        local folds = config.tool_folds ~= false
        vim.wo[win].foldenable = folds
        if folds then
            vim.wo[win].foldmethod = 'expr'
            vim.wo[win].foldexpr = "v:lua.require'llm-requester.chat.ui'.fold_expr(v:lnum)"
            vim.wo[win].foldtext = "v:lua.require'llm-requester.chat.ui'.fold_text()"
            vim.wo[win].foldminlines = 1
            vim.wo[win].foldlevel = config.tool_folds_closed ~= false and 0 or 99
        end
    end
end

local function setup_keymaps()
    local config = state.config
    local handlers = state.handlers

    if not is_valid_buf(state.prompt_buf) or not is_valid_buf(state.response_buf) then
        return
    end

    local function map(buf, mode, lhs, callback, description)
        if lhs and lhs ~= '' then
            api.nvim_buf_set_keymap(buf, mode, lhs, '', {
                callback = callback,
                noremap = true,
                silent = true,
                desc = description,
            })
        end
    end

    map(state.prompt_buf, 'i', '<M-CR>', handlers.on_send, 'Send LLM request')
    map(state.prompt_buf, 'n', config.request_keys, handlers.on_send, 'Send LLM request')
    map(state.prompt_buf, 'n', config.stop_keys, handlers.on_stop, 'Stop LLM request')
    map(state.prompt_buf, 'n', config.close_keys, handlers.on_close, 'Close LLM chat')
    map(state.prompt_buf, 'n', config.clear_keys, handlers.on_clear, 'Start a new LLM chat')
    map(state.prompt_buf, 'n', config.compact_keys, handlers.on_compact, 'Compact chat context')
    map(state.response_buf, 'n', config.stop_keys, handlers.on_stop, 'Stop LLM request')
    map(state.response_buf, 'n', config.close_keys, handlers.on_close, 'Close LLM chat')
    map(state.response_buf, 'n', config.clear_keys, handlers.on_clear, 'Start a new LLM chat')
    map(state.response_buf, 'n', config.compact_keys, handlers.on_compact, 'Compact chat context')
end

local function set_buffer_name(buf, name)
    if not is_valid_buf(buf) then
        return
    end

    local current = api.nvim_buf_get_name(buf)
    if current == '' or current:match('%[chat%]') or current:match('%[agent%]') then
        pcall(api.nvim_buf_set_name, buf, name)
    end
end

local function set_buffer_names(mode)
    set_buffer_name(state.prompt_buf, '[' .. mode .. '] Enter your prompt')
    set_buffer_name(state.response_buf, '[' .. mode .. '] Response')
end

local function append_user(text)
    local lines = vim.split(text, '\n', { plain = true })
    utils.append_to_buf(state.response_buf, vim.list_extend({ '', 'Me:' }, lines))
end

local function append_assistant(text)
    local lines = vim.split(text, '\n', { plain = true })
    utils.append_to_buf(state.response_buf, vim.list_extend({ '', 'Assistant:' }, lines))
end

local function format_arguments(arguments)
    local value = tostring(arguments or ''):gsub('%s+', ' ')
    if #value > 300 then
        value = value:sub(1, 300) .. '...'
    end
    return value
end

local function append_tool_call(call)
    local name = type(call) == 'table' and type(call['function']) == 'table' and call['function'].name or '?'
    local arguments = type(call) == 'table' and type(call['function']) == 'table' and call['function'].arguments or ''
    utils.append_to_buf(state.response_buf, {
        '',
        '  [tool] ' .. name .. ' ' .. format_arguments(arguments),
    })
end

local function preview_lines(text, limit)
    local lines = vim.split(tostring(text or ''), '\n', { plain = true })
    local result = {}
    for index = 1, math.min(#lines, limit) do
        table.insert(result, '  [out] ' .. lines[index])
    end
    if #lines > limit then
        table.insert(result, string.format('  [out] ... (%d more lines)', #lines - limit))
    end
    return result
end

local function append_tool_result(text)
    local lines = { '  [result]' }
    vim.list_extend(lines, preview_lines(text, 12))
    utils.append_to_buf(state.response_buf, lines)
end

---Fold expression for tool blocks. A blank line separates consecutive blocks.
function Ui.fold_expr(lnum)
    local line = vim.fn.getline(lnum)
    if line:match('^%s*%[tool%]')
        or line:match('^%s*%[result%]')
        or line:match('^%s*%[out%]') then
        return 1
    end
    return 0
end

---Compact text for a collapsed tool block.
function Ui.fold_text()
    local start_line = tonumber(vim.v.foldstart) or 1
    local end_line = tonumber(vim.v.foldend) or start_line
    local line = (vim.fn.getline(start_line) or ''):gsub('^%s+', '')
    if #line > 120 then
        line = line:sub(1, 120) .. '...'
    end

    local hidden = math.max(0, end_line - start_line)
    if hidden > 0 then
        return string.format('%s  (+%d lines)', line, hidden)
    end
    return line
end

function Ui.setup(config, handlers)
    state.config = config
    state.handlers = handlers or {}
end

function Ui.is_open()
    return is_valid_win(state.prompt_win) and is_valid_win(state.response_win)
end

function Ui.open(session)
    if Ui.is_open() then
        apply_window_options()
        Ui.focus_prompt()
        return
    end

    close_stale_windows()

    local prompt_buf = is_valid_buf(state.prompt_buf) and state.prompt_buf or nil
    local response_buf = is_valid_buf(state.response_buf) and state.response_buf or nil

    local prompt_win, new_prompt_buf, response_win, new_response_buf = utils.create_chat_split(
        state.config.split_ratio,
        state.config.prompt_split_ratio,
        prompt_buf,
        response_buf
    )

    state.prompt_win = prompt_win
    state.response_win = response_win
    state.prompt_buf = new_prompt_buf
    state.response_buf = new_response_buf
    state.speed = nil

    apply_window_options()

    local mode = mode_of(session)
    vim.wo[prompt_win].winbar = string.format(' [%s] Prompt', mode)
    setup_keymaps()
    set_buffer_names(mode)
    Ui.render(session)
end

function Ui.close()
    close_stale_windows()
end

function Ui.focus_prompt()
    if is_valid_win(state.prompt_win) then
        api.nvim_set_current_win(state.prompt_win)
        vim.cmd('startinsert')
    end
end

function Ui.render(session)
    if not is_valid_buf(state.response_buf) then
        return
    end

    state.speed = nil
    utils.show_in_buf(state.response_buf, {})

    if session.compaction and type(session.compaction.summary) == 'string' then
        utils.append_to_buf(state.response_buf, {
            string.format(
                '[earlier context compacted: %d messages summarized]',
                tonumber(session.compaction.compacted_messages) or 0
            ),
        })
    end

    local results_by_id = {}
    for _, message in ipairs(session.messages or {}) do
        if message.role == 'tool' and type(message.tool_call_id) == 'string' then
            results_by_id[message.tool_call_id] = message
        end
    end

    local rendered_results = {}

    for _, message in ipairs(session.messages or {}) do
        if message.role == 'user' then
            append_user(message.content)
        elseif message.role == 'assistant' then
            local has_calls = message.tool_calls and #message.tool_calls > 0
            if message.content ~= '' then
                append_assistant(message.content)
            elseif has_calls then
                utils.append_to_buf(state.response_buf, { '', 'Assistant:' })
            end

            for _, call in ipairs(message.tool_calls or {}) do
                append_tool_call(call)

                local result = results_by_id[call.id]
                if result and not rendered_results[call.id] then
                    append_tool_result(result.content)
                    rendered_results[call.id] = true
                end
            end
        elseif message.role == 'tool' then
            if not rendered_results[message.tool_call_id] then
                append_tool_result(message.content)
                rendered_results[message.tool_call_id] = true
            end
        end
    end

    local mode = mode_of(session)
    if is_valid_win(state.prompt_win) then
        vim.wo[state.prompt_win].winbar = string.format(' [%s] Prompt', mode)
    end
    set_title(session)

    if is_valid_win(state.response_win) then
        utils.scroll_window_end(state.response_win)
    end
end

function Ui.append_user_message(text)
    if not is_valid_buf(state.response_buf) then
        return
    end

    append_user(text)
    if is_valid_win(state.response_win) then
        utils.scroll_window_end(state.response_win)
    end
end

function Ui.start_assistant_message()
    if not is_valid_buf(state.response_buf) then
        return
    end

    utils.append_to_buf(state.response_buf, { '', 'Assistant:' })
    if is_valid_win(state.response_win) then
        utils.scroll_window_end(state.response_win)
    end
end

function Ui.append_stream(text)
    if not is_valid_buf(state.response_buf) or not text or text == '' then
        return
    end

    api.nvim_buf_set_option(state.response_buf, 'modifiable', true)
    utils.append_to_last_line(state.response_buf, text)
    api.nvim_buf_set_option(state.response_buf, 'modifiable', false)

    if is_valid_win(state.response_win) then
        utils.scroll_window_end(state.response_win)
    end
end

function Ui.append_error(message)
    if not is_valid_buf(state.response_buf) then
        return
    end

    local lines = vim.split('[error] ' .. tostring(message), '\n', { plain = true })
    utils.append_to_buf(state.response_buf, vim.list_extend({ '' }, lines))

    if is_valid_win(state.response_win) then
        utils.scroll_window_end(state.response_win)
    end
end

function Ui.append_tool_call(call)
    if not is_valid_buf(state.response_buf) then
        return
    end

    append_tool_call(call)

    if is_valid_win(state.response_win) then
        utils.scroll_window_end(state.response_win)
    end
end

function Ui.append_tool_result(text)
    if not is_valid_buf(state.response_buf) then
        return
    end

    append_tool_result(text)

    if is_valid_win(state.response_win) then
        utils.scroll_window_end(state.response_win)
    end
end

function Ui.append_notice(message)
    if not is_valid_buf(state.response_buf) then
        return
    end

    local lines = vim.split(tostring(message), '\n', { plain = true })
    utils.append_to_buf(state.response_buf, vim.list_extend({ '' }, lines))

    if is_valid_win(state.response_win) then
        utils.scroll_window_end(state.response_win)
    end
end

function Ui.set_usage(session)
    set_title(session)
end

---Updates the speed shown in the response winbar.
function Ui.set_speed(session, speed)
    state.speed = speed
    set_title(session)
end

---Window ids of the open chat (prompt, response). Used by integration tests.
function Ui.windows()
    return state.prompt_win, state.response_win
end

function Ui.get_prompt_text()
    if not is_valid_buf(state.prompt_buf) then
        return ''
    end

    return table.concat(utils.get_content(state.prompt_buf), '\n')
end

-- Restores text into the prompt buffer. Existing draft text is preserved and
-- the restored message is appended after a blank line.
function Ui.set_prompt_text(text)
    if not is_valid_buf(state.prompt_buf) or not text or text == '' then
        return
    end

    local current = table.concat(utils.get_content(state.prompt_buf), '\n')
    if current:match('%S') then
        text = current .. '\n\n' .. text
    end

    local lines = vim.split(text, '\n', { plain = true })
    utils.show_in_buf_mutable(state.prompt_buf, lines)

    if is_valid_win(state.prompt_win) then
        local last_line = lines[#lines] or ''
        api.nvim_win_set_cursor(state.prompt_win, { #lines, #last_line })
    end
end

function Ui.clear_prompt()
    if is_valid_buf(state.prompt_buf) then
        utils.show_in_buf_mutable(state.prompt_buf, {})
    end
end

return Ui
