local Tools = {}

local api = vim.api
local fn = vim.fn

Tools.default_config = {
    api_type = 'openai', -- 'openai' only
    openai_model = 'gpt-4o-mini',
    openai_url = 'https://api.openai.com/v1/chat/completions',
    api_key_file = '', -- Path to file containing the API key

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
    timeout = nil,
    autoapprove_count = 10,  -- Number of times tool can be autoapproved before next approve window is shown
}

local utils = require("llm-requester.utils")
local json_reconstruct = require("llm-requester.json_reconstruct")

-- Helper function to get API key from file
local function get_api_key(config)
    if config.api_key_file ~= '' then
        return utils.read_api_key_from_file(config.api_key_file)
    else
        return ''
    end
end

local config = vim.deepcopy(Tools.default_config)
local approve_window_shown = false

local always_approve_set = {
    list_files = true,
    read_file = true,
}

-- Here are tools that have only auto aprove only for count times
local limited_approve_set = {
    create_directory = 10,
    edit_files = 10,
    write_whole_file = 10,
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
            '--model', config.openai_model,
            '--openai-base-url', config.openai_url,
            '--provider', config.api_type,
            '--context-size', tostring(config.context_size),
            '--max-rps', tostring(config.max_rps),
            '--port', tostring(config.server_port),
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
    if config.timeout then
        table.insert(command, '--timeout')
        table.insert(command, tostring(config.timeout))
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
                LLM_API_KEY = get_api_key(config) ~= '' and get_api_key(config) or 'None',
            }
    })

    vim.keymap.set('n', config.open_prompt_window_key, Tools.open_chat_window, { desc = 'Test action' })
    vim.keymap.set('v', config.open_prompt_window_key, Tools.open_chat_window, { desc = 'Test action' })
    vim.keymap.set('n', config.open_agent_window_key, Tools.open_agent_window, { desc = 'Test action' })
    vim.keymap.set('v', config.open_agent_window_key, Tools.open_agent_window, { desc = 'Test action' })
    vim.api.nvim_create_user_command('LLMRequesterChat', Tools.open_chat_window, { range = true })
    vim.api.nvim_create_user_command('LLMRequesterAgent', Tools.open_agent_window, { range = true })
    vim.api.nvim_create_user_command('LLMRequesterSetOpenaiModel', Tools.set_openai_model, { range = true, nargs = 1 })
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
        usage = nil,
    },
    agent = {
        prompt_buf = nil,
        response_buf = nil,
        session_id = nil,
        usage = nil,
    }
}

local function format_usage(usage)
    if usage == nil then
        return ""
    end
    return "(total/in/out: " .. tostring(usage.total_tokens) .. "/" .. tostring(usage.input) .. "/" .. tostring(usage.output) .. ")"
end

local function add_usage(usage_l, usage_r)
    if usage_l == nil then
        return usage_r
    end

    if usage_r == nil then
        return usage_l
    end

    return {
        total_tokens = usage_l.total_tokens + usage_r.total_tokens,
        input = usage_l.input + usage_r.input,
        output = usage_l.output + usage_r.output,
    }
end


function Tools.open_chat_window()
    Tools.open_chat_window_impl('chat')
end

function Tools.open_agent_window()
    Tools.open_chat_window_impl('agent')
end

function Tools.fold_all_tool_calls(buf)
    -- Fold all text between BEGIN_USE_TOOL and END_USE_TOOL tags
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local folds = {}

    -- Find all BEGIN_USE_TOOL and END_USE_TOOL pairs
    local start_line = nil
    for i, line in ipairs(lines) do
        if line:match("BEGIN_USE_TOOL") then
            start_line = i - 1  -- Convert to 0-indexed
        elseif line:match("END_USE_TOOL") and start_line ~= nil then
            table.insert(folds, {start_line, i - 1})  -- Convert to 0-indexed
            start_line = nil
        end
    end

    -- Apply folds
    for _, fold in ipairs(folds) do
        api.nvim_buf_call(buf, function()
            vim.cmd(fold[1] + 1 .. "," .. fold[2] + 1 .. "fold")
        end)
    end
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

    api.nvim_buf_set_name(cdata.prompt_buf, "[" .. chat_type .. "] Enter your prompt:")
    api.nvim_buf_set_name(cdata.response_buf, "[" .. current_chat_type .. "] Response " .. format_usage(cdata.usage) .. ":")

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
    local cdata = ChatData[current_chat_type]
    local response_buf = cdata.response_buf
    Tools.send_start_session(current_chat_type)
    utils.show_in_buf(response_buf, {})
    cdata.usage = nil
    api.nvim_buf_set_name(cdata.response_buf, "[" .. current_chat_type .. "] Response:")

    api.nvim_set_current_win(prompt_win)
end

local function handle(_, data)
    local response_buf = ChatData[current_chat_type].response_buf
    local response = table.concat(data, '')
    local success, decoded = pcall(vim.json.decode, response)
    if success then
        if decoded.usage and decoded.usage ~= vim.NIL then
            local cdata = ChatData[current_chat_type]
            cdata.usage = add_usage(cdata.usage, decoded.usage)
            api.nvim_buf_set_name(cdata.response_buf, "[" .. current_chat_type .. "] Response " .. format_usage(cdata.usage) .. ":")
        end

        utils.append_to_buf(response_buf, vim.split(decoded.message, '\n'))
        Tools.fold_all_tool_calls(response_buf)
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
                if decoded.usage and decoded.usage ~= vim.NIL then
                    local cdata = ChatData[current_chat_type]
                    cdata.usage = add_usage(cdata.usage, decoded.usage)
                    api.nvim_buf_set_name(cdata.response_buf, "[" .. current_chat_type .. "] Response " .. format_usage(cdata.usage) .. ":")
                end

                utils.append_to_last_line(response_buf, decoded.message)
                if decoded.request_id and decoded.request_id ~= vim.NIL then
                    Tools.process_required_approval(decoded)
                end
                Tools.fold_all_tool_calls(response_buf)
                utils.scroll_window_end(response_win)
            end)
            api.nvim_buf_set_option(response_buf, 'modifiable', false)
        end
    end
end

local function make_editor_context()
    opened_file = utils.get_first_filename_from_buffers()
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
    local tools = decoded.tools
    for _, tool in ipairs(tools) do
        local function on_approve()
            Tools.send_approve(request_id, true)
            approve_window_shown = false
        end

        -- process autoapprove
        if always_approve_set[tool.name] then
            if tool.arguments.path == nil or utils.is_subdirectory(tool.arguments.path, vim.fn.getcwd()) then
                on_approve()
                return
            end
        end

        -- process limited autoapprove
        if limited_approve_set[tool.name] ~= nil and limited_approve_set[tool.name] > 0 then
            if tool.arguments.path == nil or utils.is_subdirectory(tool.arguments.path, vim.fn.getcwd()) then
                limited_approve_set[tool.name] = limited_approve_set[tool.name] - 1
                on_approve()
                return
            end
        end

        local popup_content = "LLM wants to use tool:\n - " .. format_tool(tool) .. "\n" ..
                              "approve ((y)es/(n)o/(A)lways approve)?"
        local function on_always_approve()
            Tools.send_approve(request_id, true)
            limited_approve_set[tool.name] = config.autoapprove_count
            approve_window_shown = false
        end
        local function on_deny()
            Tools.send_approve(request_id, false)
            approve_window_shown = false
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
        model = config.openai_model,
        provider_base_url = config.openai_url,
        api_key = get_api_key(config),
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

