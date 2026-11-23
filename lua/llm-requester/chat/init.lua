-- Public chat API: session lifecycle, request orchestration, commands.

local api = vim.api
local utils = require('llm-requester.utils')
local Store = require('llm-requester.chat.store')
local Client = require('llm-requester.chat.client')
local Agent = require('llm-requester.chat.agent')
local Ui = require('llm-requester.chat.ui')

local Chat = {}

Chat.default_config = {
    openai_url = 'https://api.openai.com/v1/chat/completions',
    openai_model = 'gpt-4o-mini',
    api_key_file = '',
    api_key = '',

    temperature = 0.2,
    top_p = nil,
    stream = true,
    timeout = nil,
    connect_timeout = 15,
    stall_timeout = nil,
    no_verify_ssl = false,
    additional_params = {},

    split_ratio = 0.5,
    prompt_split_ratio = 0.2,
    open_prompt_window_key = '<leader>ac',
    open_agent_window_key = '<leader>ai',
    request_keys = '<leader>r',
    stop_keys = '<leader>cx',
    close_keys = '<leader>q',
    clear_keys = '<leader>cc',

    sessions_dir = vim.fn.stdpath('cache') .. '/llm-requester/sessions',
    continue_last_session = true,
    system_prompt = [[
You are a helpful and highly skilled software developer assistant.
You must help user with their task.
]],

    agent = {
        system_prompt = [[
You are an autonomous software development assistant running inside Neovim.
You can inspect and modify files and run shell commands through the provided tools.
Prefer reading the relevant files before changing them, and keep changes focused.
Explain briefly what you are about to do, then call the tools you need.
]],
        tool_choice = 'auto',
        max_tool_iterations = 24,
        iteration_limit_step = 24,
        confirm_iteration_limit = nil,
        max_tool_calls_per_round = 20,
        max_file_bytes = 200000,
        max_write_bytes = 200000,
        max_read_lines = 2000,
        max_tool_output_bytes = 50000,
        max_stored_tool_output = 8000,
        max_list_entries = 500,
        command_timeout = 60,
        auto_approve_limit = 20,
        allow_read_visible_in_cwd = true,
        confirm = nil,
    },
}

local config = vim.deepcopy(Chat.default_config)
local store = nil

local state = {
    session = nil,
    process = nil,
    agent = nil,
    pending = false,
    generation = 0,
    stream_text = '',
    current_user_text = nil,
}

local function notify(message, level)
    vim.notify('llm-requester: ' .. message, level or vim.log.levels.INFO)
end

local function save_session()
    if not state.session or state.session:is_empty() then
        return false
    end

    state.session.model = config.openai_model

    local ok, err = store:save(state.session)
    if not ok then
        notify('failed to save chat session: ' .. tostring(err), vim.log.levels.WARN)
    end
    return ok
end

local function ensure_session(mode)
    mode = mode == 'agent' and 'agent' or 'chat'

    if state.session and state.session.mode == mode then
        return state.session
    end

    if state.session then
        save_session()
    end
    state.agent = nil

    local cwd = vim.fn.getcwd()

    if config.continue_last_session then
        local latest = store:latest(cwd, mode)
        if latest then
            state.session = latest
            return latest
        end
    end

    state.session = store:new_session(cwd, config.openai_model, mode)
    return state.session
end

local function get_agent(session)
    if state.agent and state.agent.session == session then
        return state.agent
    end

    state.agent = Agent.new({
        session = session,
        config = config,
    })
    return state.agent
end

local function cancel_request()
    state.generation = state.generation + 1
    state.pending = false
    state.stream_text = ''
    state.current_user_text = nil

    if state.process then
        pcall(function()
            state.process:kill(9)
        end)
        state.process = nil
    end

    if state.agent then
        state.agent:cancel()
    end
end

local function make_editor_context()
    local filename = utils.get_first_filename_from_buffers()
    if not filename then
        return ''
    end

    return '- user look at existing ' .. filename .. ' file'
end

function Chat.setup(user_config)
    config = vim.tbl_deep_extend('force', vim.deepcopy(Chat.default_config), user_config or {})
    config.sessions_dir = vim.fn.expand(config.sessions_dir)
    store = Store.new(config.sessions_dir)

    Ui.setup(config, {
        on_send = Chat.send,
        on_stop = Chat.stop,
        on_close = Chat.close,
        on_clear = Chat.new_session,
    })

    local commands = {
        { 'LLMRequesterChat', Chat.open },
        { 'LLMRequesterAgent', Chat.open_agent },
        { 'LLMRequesterChatNew', Chat.new_session },
        { 'LLMRequesterChatStop', Chat.stop },
        { 'LLMRequesterChatSessions', Chat.select_session },
    }

    for _, command in ipairs(commands) do
        api.nvim_create_user_command(command[1], command[2], { force = true })
    end

    api.nvim_create_user_command('LLMRequesterSetOpenaiModel', Chat.set_openai_model, {
        nargs = 1,
        force = true,
    })

    if config.open_prompt_window_key and config.open_prompt_window_key ~= '' then
        vim.keymap.set({ 'n', 'v' }, config.open_prompt_window_key, Chat.open, {
            desc = 'LLM chat',
        })
    end

    if config.open_agent_window_key and config.open_agent_window_key ~= '' then
        vim.keymap.set({ 'n', 'v' }, config.open_agent_window_key, Chat.open_agent, {
            desc = 'LLM agent chat',
        })
    end

    local group = api.nvim_create_augroup('LLMRequesterChat', { clear = true })
    api.nvim_create_autocmd('VimLeavePre', {
        group = group,
        callback = function()
            save_session()
        end,
    })
end

local function open_mode(mode)
    local current_mode = state.session and state.session.mode or 'chat'
    if state.pending and current_mode ~= mode then
        notify(
            'a request is in progress; stop it before switching chat modes',
            vim.log.levels.WARN
        )
        mode = current_mode
    end

    local was_open = Ui.is_open()
    local session = ensure_session(mode)

    Ui.open(session)

    -- Restore an in-flight response when the window was closed and reopened.
    if not was_open and state.pending then
        Ui.start_assistant_message()
        Ui.append_stream(state.stream_text)
    end
end

function Chat.open()
    open_mode('chat')
end

function Chat.open_agent()
    open_mode('agent')
end

function Chat.close()
    Ui.close()
end

function Chat.stop()
    if not state.pending then
        notify('no active request', vim.log.levels.WARN)
        return
    end

    local stopped_text = state.current_user_text or ''
    cancel_request()

    local session = state.session
    if session then
        local removed = session:rollback_pending_request()
        if stopped_text == '' and removed then
            stopped_text = removed
        end

        if session:is_empty() then
            local ok, err = store:delete(session.id)
            if not ok then
                notify('failed to delete empty session: ' .. tostring(err), vim.log.levels.WARN)
            end
        else
            save_session()
        end
    end

    Ui.set_prompt_text(stopped_text)

    if Ui.is_open() then
        if session then
            Ui.render(session)
        end
        Ui.append_notice('[request stopped]')
        Ui.focus_prompt()
    end

    notify('request stopped')
end

function Chat.new_session()
    local mode = state.session and state.session.mode or 'chat'
    cancel_request()

    local was_open = Ui.is_open()
    state.agent = nil
    state.session = store:new_session(vim.fn.getcwd(), config.openai_model, mode)

    if was_open then
        Ui.render(state.session)
        Ui.clear_prompt()
        Ui.focus_prompt()
    else
        Ui.open(state.session)
    end
end

function Chat.select_session()
    local entries = store:list()
    if #entries == 0 then
        notify('no saved chat sessions found', vim.log.levels.WARN)
        return
    end

    local items = {}
    for _, entry in ipairs(entries) do
        table.insert(items, {
            id = entry.id,
            session = entry.session,
            label = string.format(
                '%s  %s  [%s, %d messages]',
                os.date('%Y-%m-%d %H:%M', entry.session.updated_at or 0),
                entry.session.cwd or '?',
                entry.session.mode or 'chat',
                #entry.session.messages
            ),
        })
    end

    vim.ui.select(items, {
        prompt = 'Select chat session:',
        format_item = function(item)
            return item.label
        end,
    }, function(item)
        if not item then
            return
        end

        if state.session and state.session.id == item.id then
            if Ui.is_open() then
                Ui.focus_prompt()
            else
                Ui.open(item.session)
            end
            return
        end

        cancel_request()
        save_session()

        state.agent = nil
        state.session = item.session

        if Ui.is_open() then
            Ui.render(item.session)
            Ui.clear_prompt()
            Ui.focus_prompt()
        else
            Ui.open(item.session)
        end
    end)
end

local function send_chat(session, generation)
    Ui.start_assistant_message()

    local messages = session:build_messages(config.system_prompt, make_editor_context())

    state.process = Client.request({
        config = config,
        messages = messages,
        on_delta = function(chunk)
            if generation ~= state.generation then
                return
            end

            state.stream_text = state.stream_text .. chunk
            Ui.append_stream(chunk)
        end,
        on_usage = function(usage)
            if generation ~= state.generation then
                return
            end

            session:add_usage(usage)
        end,
        on_finish = function(content)
            if generation ~= state.generation then
                return
            end

            state.pending = false
            state.process = nil
            state.stream_text = ''
            state.current_user_text = nil

            session:add_assistant(content)
            save_session()
            Ui.set_usage(session)
        end,
        on_error = function(message)
            if generation ~= state.generation then
                return
            end

            state.pending = false
            state.process = nil
            state.stream_text = ''
            state.current_user_text = nil

            Ui.append_error(message)
            save_session()
            notify(message, vim.log.levels.ERROR)
        end,
    })
end

local function send_agent(session, generation)
    local agent = get_agent(session)

    agent:send({
        on_assistant_start = function()
            if generation ~= state.generation then
                return
            end

            state.stream_text = ''
            Ui.start_assistant_message()
        end,
        on_delta = function(chunk)
            if generation ~= state.generation then
                return
            end

            state.stream_text = state.stream_text .. chunk
            Ui.append_stream(chunk)
        end,
        on_usage = function(usage)
            if generation ~= state.generation then
                return
            end
            session:add_usage(usage)
        end,
        on_tool_start = function(call)
            if generation ~= state.generation then
                return
            end
            Ui.append_tool_call(call)
        end,
        on_tool_result = function(_, result)
            if generation ~= state.generation then
                return
            end
            Ui.append_tool_result(result)
        end,
        on_notice = function(message)
            if generation ~= state.generation then
                return
            end
            Ui.append_notice(message)
        end,
        on_change = function()
            if generation ~= state.generation then
                return
            end
            save_session()
        end,
        on_finish = function()
            if generation ~= state.generation then
                return
            end

            state.pending = false
            state.process = nil
            state.stream_text = ''
            state.current_user_text = nil

            save_session()
            Ui.set_usage(session)
        end,
        on_error = function(message)
            if generation ~= state.generation then
                return
            end

            state.pending = false
            state.process = nil
            state.stream_text = ''
            state.current_user_text = nil

            Ui.append_error(message)
            save_session()
            notify(message, vim.log.levels.ERROR)
        end,
    }, make_editor_context())
end

function Chat.send()
    if not Ui.is_open() then
        return
    end

    if state.pending then
        notify('a request is already in progress', vim.log.levels.WARN)
        return
    end

    local text = Ui.get_prompt_text()
    if not text:match('%S') then
        return
    end

    state.generation = state.generation + 1
    local generation = state.generation
    state.pending = true
    state.stream_text = ''
    state.current_user_text = text

    local session = state.session or ensure_session('chat')

    Ui.append_user_message(text)
    Ui.clear_prompt()

    session:add_user(text)
    save_session()

    if session.mode == 'agent' then
        send_agent(session, generation)
    else
        send_chat(session, generation)
    end
end

function Chat.set_openai_model(opts)
    local model = opts and opts.fargs and opts.fargs[1]
    if not model or model == '' then
        notify('model name is required', vim.log.levels.WARN)
        return
    end

    config.openai_model = model

    if state.session then
        state.session.model = model
        save_session()
    end

    notify('model set to ' .. model)
end

return Chat
