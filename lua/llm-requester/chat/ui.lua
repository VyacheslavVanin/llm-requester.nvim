-- Chat window rendering and buffer/window lifecycle.
--
-- The module owns only presentation concerns. Session state and request
-- orchestration live in llm-requester.chat.

local api = vim.api
local utils = require('llm-requester.utils')

local Ui = {}

local state = {
    config = nil,
    handlers = {},
    prompt_win = nil,
    response_win = nil,
    prompt_buf = nil,
    response_buf = nil,
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

local function set_title(session)
    if not is_valid_win(state.response_win) then
        return
    end

    vim.wo[state.response_win].winbar = string.format(
        ' [chat] Response %s',
        format_usage(session.usage)
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
    map(state.prompt_buf, 'n', config.close_keys, handlers.on_close, 'Close LLM chat')
    map(state.prompt_buf, 'n', config.clear_keys, handlers.on_clear, 'Start a new LLM chat')
    map(state.response_buf, 'n', config.close_keys, handlers.on_close, 'Close LLM chat')
    map(state.response_buf, 'n', config.clear_keys, handlers.on_clear, 'Start a new LLM chat')
end

local function set_buffer_name(buf, name)
    if not is_valid_buf(buf) then
        return
    end

    if api.nvim_buf_get_name(buf) == '' then
        pcall(api.nvim_buf_set_name, buf, name)
    end
end

local function set_buffer_names()
    set_buffer_name(state.prompt_buf, '[chat] Enter your prompt')
    set_buffer_name(state.response_buf, '[chat] Response')
end

local function append_user(text)
    local lines = vim.split(text, '\n', { plain = true })
    utils.append_to_buf(state.response_buf, vim.list_extend({ '', 'Me:' }, lines))
end

local function append_assistant(text)
    local lines = vim.split(text, '\n', { plain = true })
    utils.append_to_buf(state.response_buf, vim.list_extend({ '', 'Assistant:' }, lines))
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

    vim.wo[prompt_win].winbar = ' [chat] Prompt'
    setup_keymaps()
    set_buffer_names()
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

    utils.show_in_buf(state.response_buf, {})

    for _, message in ipairs(session.messages or {}) do
        if message.role == 'user' then
            append_user(message.content)
        elseif message.role == 'assistant' then
            append_assistant(message.content)
        end
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

function Ui.set_usage(session)
    set_title(session)
end

function Ui.get_prompt_text()
    if not is_valid_buf(state.prompt_buf) then
        return ''
    end

    return table.concat(utils.get_content(state.prompt_buf), '\n')
end

function Ui.clear_prompt()
    if is_valid_buf(state.prompt_buf) then
        utils.show_in_buf_mutable(state.prompt_buf, {})
    end
end

return Ui
