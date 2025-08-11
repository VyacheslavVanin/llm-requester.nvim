local Tools = {}

local api = vim.api
local fn = vim.fn

Tools.default_config = {
    api_type = 'ollama', -- 'ollama' or 'openai'
    ollama_model = 'llama2',
    ollama_url = 'http://localhost:11434',
    openai_model = 'llama2',
    openai_url = 'https://openrouter.ai/api/v1',
    openai_api_key = '', -- Set your OpenAI API key here or via setup()

    temperature = 0.2,
    top_k = 20,
    top_p = nil,
    context_size = 2048,

    split_ratio = 0.5,
    prompt_split_ratio = 0.2, -- parameter to control dimensions of prompt and response windows
    open_prompt_window_key = '<leader>ac',
    open_agent_window_key = '<leader>ai',
    request_keys = '<leader>r',
    close_keys = '<leader>q',
    clear_keys = '<leader>cc',
    stream = true,
    max_rps = 100,
    no_verify_ssl = false,
    server_port = 8000,
}

local utils = require("llm-requester.utils")
local json_reconstruct = require("llm-requester.json_reconstruct")

local config = vim.deepcopy(Tools.default_config)
local approve_window_shown = false
local always_approve_set = {
    list_files = true,
    read_file = true,
    create_directory = true,
    edit_files = true,
    write_whole_file = true,
}

local chat_session_id = nil
local agent_session_id = nil
local session_id = nil
local current_chat_type = nil

function Tools.setup(main_config)
    config = vim.tbl_extend('force', config, main_config or {})

    -- setup mcp http host --
    local install_script = vim.api.nvim_get_runtime_file('mcp-http-host/install.sh', true)
    if #install_script ~= 0 then
        fn.jobstart({'bash', install_script[1]}, {
            on_stdout = function(_, data) end,
            on_exit = nil,
            stdout_buffered = true,
        })
    end

    local error = ""
    local stdout = ""

    -- start mcp http host --
    local mcp_http_host_dir = vim.api.nvim_get_runtime_file('mcp-http-host', false)[1]

    local command = {
            'uv', 'run', 'main.py',
            '--current-directory', vim.fn.getcwd(),
            '--stream', --tostring(config.stream),
            '--model', config.api_type == "ollama" and config.ollama_model or config.openai_model,
            '--ollama-base-url', config.ollama_url,
            '--openai-base-url', config.openai_url,
            '--provider', config.api_type,
            '--context-size', tostring(config.context_size),
            '--max-rps', tostring(config.max_rps),
            '--port', tostring(config.server_port)
        }
    if config.top_p ~= nil then
        table.insert(command, '--top_p')
        table.insert(command, tostring(config.top_p))
    end
    if config.top_k ~= nil then
        table.insert(command, '--top_k')
        table.insert(command, tostring(config.top_k))
    end
    if config.temperature ~= nil then
        table.insert(command, '--temperature')
        table.insert(command, tostring(config.temperature))
    end
    if config.no_verify_ssl then
        table.insert(command, '--no-verify-ssl')
    end
    fn.jobstart(command,
        {
            on_stdout = function(_, data)
                -- TODO: here we can save output from server to some log
                stdout = stdout .. table.concat(data, '\n')
            end,
            on_stderr = function(_, data)
                -- TODO: here we can save output from server to some log
                error = error .. table.concat(data, '\n')
            end,
            on_exit = function(_, exit_code)
                vim.notify(error)
                vim.notify(stdout)
            end,
            stdout_buffered = true,
            cwd = mcp_http_host_dir,
            env = {
                LLM_API_KEY = (config.openai_api_key ~= '' and config.openai_api_key) or 'None',
            }
    })

    vim.keymap.set('n', config.open_prompt_window_key, Tools.open_chat_window, { desc = 'Test action' })
    vim.keymap.set('v', config.open_prompt_window_key, Tools.open_chat_window, { desc = 'Test action' })
    vim.keymap.set('n', config.open_agent_window_key, Tools.open_agent_window, { desc = 'Test action' })
    vim.keymap.set('v', config.open_agent_window_key, Tools.open_agent_window, { desc = 'Test action' })
    vim.api.nvim_create_user_command('LLMRequester', Tools.open_chat_window, { range = true })
    vim.api.nvim_create_user_command('LLMRequesterSetOllamaModel', Tools.set_ollama_model, { range = true, nargs = 1 })
    vim.api.nvim_create_user_command('LLMRequesterSetOpenaiModel', Tools.set_openai_model, { range = true, nargs = 1 })
end

function Tools.set_ollama_model(attr)
    config.ollama_model = attr.fargs[1]
end

function Tools.set_openai_model(attr)
    config.openai_model = attr.fargs[1]
end

local prompt_win, response_win

local ChatData = {
    chat = {
        prompt_buf = nil,
        response_buf = nil,
        session_id = nil,
    },
    agent = {
        prompt_buf = nil,
        response_buf = nil,
        session_id = nil,
    }
}

function Tools.open_chat_window()
    Tools.open_chat_window_impl('chat')
end

function Tools.open_agent_window()
    Tools.open_chat_window_impl('agent')
end

function Tools.open_chat_window_impl(chat_type)
    if (prompt_win and api.nvim_win_is_valid(prompt_win)) or
       (response_win and api.nvim_win_is_valid(response_win)) then
        return
    end

    local cdata = ChatData[chat_type]
    if cdata.session_id == nil then
        Tools.send_start_session(chat_type)
    end
    session_id = cdata.session_id

    current_chat_type = chat_type
    local cdata = ChatData[chat_type]

    prompt_win, cdata.prompt_buf, response_win, cdata.response_buf =
        utils.create_chat_split(config.split_ratio, config.prompt_split_ratio,
                                cdata.prompt_buf, cdata.response_buf)

    -- Set keymaps
    local close_func = function() 
        if api.nvim_win_is_valid(prompt_win) then api.nvim_win_close(prompt_win, true) end
        if api.nvim_win_is_valid(response_win) then api.nvim_win_close(response_win, true) end
    end

    vim.keymap.set('v', config.close_keys, close_func, { desc = 'Close LLMRequester window' })
    vim.keymap.set('n', config.close_keys, close_func, { desc = 'Close LLMRequester window' })
    api.nvim_buf_set_keymap(cdata.prompt_buf, 'i', '<M-CR>', '', { callback = Tools.send_request })
    api.nvim_buf_set_keymap(cdata.prompt_buf, 'n', config.request_keys, '', { callback = Tools.send_request })
    api.nvim_buf_set_keymap(cdata.prompt_buf, 'n', config.close_keys, '', { callback = close_func })
    api.nvim_buf_set_keymap(cdata.prompt_buf, 'n', config.clear_keys, '', { callback = Tools.clear_chat })
    api.nvim_buf_set_keymap(cdata.response_buf, 'n', config.close_keys, '', { callback = close_func })
    api.nvim_buf_set_keymap(cdata.response_buf, 'n', config.clear_keys, '', { callback = Tools.clear_chat })
end

function Tools.send_request()
    local prompt_buf = ChatData[current_chat_type].prompt_buf
    local response_buf = ChatData[current_chat_type].response_buf
    local content = utils.get_content(prompt_buf)
    local text = table.concat(content, '\n')
    utils.append_to_buf(response_buf, vim.list_extend({'', 'Me:'}, content))
    Tools.make_user_request(text)

    utils.show_in_buf_mutable(prompt_buf, {})
end

function Tools.clear_chat()
    local response_buf = ChatData[current_chat_type].response_buf
    Tools.send_start_session(current_chat_type)
    utils.show_in_buf(response_buf, {})
end

local function handle(_, data)
    local response_buf = ChatData[current_chat_type].response_buf
    local response = table.concat(data, '')
    local success, decoded = pcall(vim.json.decode, response)
    if success then
        utils.append_to_buf(response_buf, vim.split(decoded.message, '\n'))
        utils.scroll_window_end(response_win)
        if decoded.requires_approval then
            Tools.process_required_approval(decoded)
        end
    end
end

local function handle_on_exit(_, exit_code)
end

local function handle_streaming_response(_, data)
    local response_buf = ChatData[current_chat_type].response_buf
    if #data > 0 then
        for _, line in ipairs(data) do
            api.nvim_buf_set_option(response_buf, 'modifiable', true)
            json_reconstruct.process_part(line, function(decoded)
                utils.append_to_last_line(response_buf, decoded.message)
                if decoded.request_id and decoded.request_id ~= vim.NIL then
                    Tools.process_required_approval(decoded)
                end
                utils.scroll_window_end(response_win)
            end)
            api.nvim_buf_set_option(response_buf, 'modifiable', false)
        end
    end
end

local function get_first_filename_from_buffers()
    -- Get the current tab page number
    local tabnr = vim.api.nvim_get_current_tabpage()

    -- Get the list of buffers in the current tab page
    local windows = vim.api.nvim_tabpage_list_wins(tabnr)

    -- Iterate through the buffers and find the first one with a valid filename
    for _, win_id in ipairs(windows) do
        local bufnr = vim.api.nvim_win_get_buf(win_id)
        local filename = vim.api.nvim_buf_get_name(bufnr)
        if filename ~= "" and filename ~= "[No Name]" then
            return filename
        end
    end

    -- Return nil if no buffer with a valid filename is found
    return nil
end

local function make_editor_context()
    opened_file = get_first_filename_from_buffers()
    if opened_file == nil then
        return ""
    end

    return "- user look at existing " .. opened_file .. " file"
end

function Tools.make_user_request(message)
    local json_data = vim.json.encode({
        input = message,
        context = make_editor_context(),
        session_id = session_id,
    })
    local response_buf = ChatData[current_chat_type].response_buf
    utils.append_to_buf(response_buf, {'', 'Agent:'})
    fn.jobstart({'curl', '-s',
                 '-X', 'POST',
                 '-H', 'Content-Type: application/json',
                 'http://localhost:' .. config.server_port .. '/user_request',
                 '-d', json_data}, {
        on_stdout = (config.stream and handle_streaming_response) or handle,
        on_exit = handle_on_exit,
        stdout_buffered = not config.stream,
    })
end

local function format_tool(tool)
    local ret = ""
    ret = tool.name .. "("
    for k, v in pairs(tool.arguments) do
        ret = ret .. "\"" .. k .. "\": \"" .. v .. "\", "
    end
    ret = ret .. ")"
    return ret
end

function Tools.process_required_approval(decoded)
    local message = decoded.message
    local request_id = decoded.request_id
    local tool = decoded.tool
    local popup_content = "LLM wants to use tool:\n - " .. format_tool(tool) .. "\n" ..
                          "approve ((y)es/(n)o/(A)lways approve)?"
    local function on_approve()
        Tools.send_approve(request_id, true)
        approve_window_shown = false
    end
    local function on_always_approve()
        Tools.send_approve(request_id, true)
        always_approve_set[tool.name] = true
        approve_window_shown = false
    end
    local function on_deny()
        Tools.send_approve(request_id, false)
        approve_window_shown = false
    end

    if always_approve_set[tool.name] then
        if tool.arguments.path == nil or utils.is_subdirectory(tool.arguments.path, vim.fn.getcwd()) then
            on_approve()
            return
        end
    end

    approve_window_shown = true
    utils.show_choose_window(
        popup_content,
        {
            y = on_approve,
            n = on_deny,
            A = on_always_approve,
        }
    )
end

function Tools.send_approve(request_id, approve)
    local json_data = vim.json.encode({
        request_id = request_id,
        approve = approve,
        session_id = session_id,
    })
    fn.jobstart({'curl', '-s',
                 '-X', 'POST',
                 '-H', 'Content-Type: application/json',
                 'http://localhost:' .. config.server_port .. '/approve',
                 '-d', json_data}, {
        on_stdout = (config.stream and handle_streaming_response) or handle,
        on_exit = handle_on_exit,
        stdout_buffered = not config.stream,
    })
end

function Tools.send_start_session(chat_type)
    local json_data = vim.json.encode({
        current_directory = vim.fn.getcwd(),
        llm_provider = config.api_type,
        model = (config.api_type == 'openai') and config.openai_model or config.ollama_model,
        provider_base_url = (config.api_type == 'openai') and config.openai_url or config.ollama_url,
        api_key = config.openai_api_key,
        temperature = config.temperature,
        context_size = config.context_size,
        stream = config.stream,
        chat_type = chat_type,
    })
    local handle = function(_, data)
        local response = table.concat(data, '')
        local success, decoded = pcall(vim.json.decode, response)
        local cdata = ChatData[chat_type]
        cdata.session_id = decoded.session_id
        session_id = cdata.session_id
    end
    local handle_on_exit = function(_, exit_code)
    end
    fn.jobstart({'curl', '-s',
                 '-X', 'POST',
                 '-H', 'Content-Type: application/json',
                 'http://localhost:' .. config.server_port .. '/start_session',
                 '-d', json_data}, {
        on_stdout = handle,
        on_exit = handle_on_exit,
        stdout_buffered = true,
    })
end

return Tools

