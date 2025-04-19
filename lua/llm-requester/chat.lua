local api = vim.api
local fn = vim.fn

local Chat = {}

Chat.default_config = {
    api_type = 'ollama', -- 'ollama' or 'openai'
    ollama_model = 'llama2',
    ollama_url = 'http://localhost:11434/api/chat',
    openai_model = 'llama2',
    openai_url = 'https://openrouter.ai/api/v1/chat/completions',
    openai_api_key = '', -- Set your OpenAI API key here or via setup()

    temperature = 0.2,
    context_window_size = 2048,

    split_ratio = 0.6,
    prompt_split_ratio = 0.2, -- parameter to control dimensions of prompt and response windows
    prompt = 'Please review, improve, and refactor the following code. Provide your suggestions in markdown format with explanations:\n\n',
    open_prompt_window_key = '<leader>ai',
    request_keys = '<leader>r',
    close_keys = '<leader>q',
    history_keys = '<leader>h',
    clear_keys = '<leader>cc',
    stream = false,
}

local config = vim.deepcopy(Chat.default_config)
local prompt_buf, response_buf
local prompt_win, response_win

local json_reconstruct = require("llm-requester.json_reconstruct")
local tools = require("llm-requester.tools")
local utils = require("llm-requester.utils")
local messages = {}

-- Show content in current buffer exclusivly
local function show_in_response_buf(content)
    utils.show_in_buf(response_buf, content)
end

-- Append lines to current buffer
local function append_to_response_buf(content)
    utils.append_to_buf(response_buf, content)
end

-- Append string to last string if buffer bufnr
local append_to_last_line = utils.append_to_last_line

-- Helper function to create windows
local function create_split()
    prompt_win, prompt_buf,
    response_win, response_buf =
                    utils.create_chat_split(config.split_ratio,
                                            config.prompt_split_ratio)

    -- Set keymaps
    local close_func = function() 
        if api.nvim_win_is_valid(prompt_win) then api.nvim_win_close(prompt_win, true) end
        if api.nvim_win_is_valid(response_win) then api.nvim_win_close(response_win, true) end
    end

    vim.keymap.set('v', config.close_keys, close_func, { desc = 'Close LLMRequester window' })
    vim.keymap.set('n', config.close_keys, close_func, { desc = 'Close LLMRequester window' })
    api.nvim_buf_set_keymap(prompt_buf, 'i', '<M-CR>', '', { callback = Chat.send_request })
    api.nvim_buf_set_keymap(prompt_buf, 'n', config.request_keys, '', { callback = Chat.send_request })
    api.nvim_buf_set_keymap(prompt_buf, 'n', config.close_keys, '', { callback = close_func })
    api.nvim_buf_set_keymap(prompt_buf, 'n', config.history_keys, '', { callback = Chat.show_history })
    api.nvim_buf_set_keymap(prompt_buf, 'n', config.clear_keys, '', { callback = Chat.clear_chat })
    api.nvim_buf_set_keymap(response_buf, 'n', config.close_keys, '', { callback = close_func })
    api.nvim_buf_set_keymap(response_buf, 'n', config.history_keys, '', { callback = Chat.show_history })
    api.nvim_buf_set_keymap(response_buf, 'n', config.clear_keys, '', { callback = Chat.clear_chat })
end

local function handle_on_exit(_, exit_code)
    if config.stream then
        json_reconstruct.finalize(function(complete_json)
            local success, decoded = pcall(vim.json.decode, complete_json)
            if success and decoded.message and decoded.message.content then
                append_to_last_line(response_buf, decoded.message.content)
            end
        end)
    end
    if exit_code == 0 then
        local lines = api.nvim_buf_get_lines(response_buf, 2, -1, false)
        local content = table.concat(lines, '\n')
        table.insert(messages, {role = "assistant", content = content})
    end

    if exit_code ~= 0 then
        show_in_response_buf({'Error: Failed to get response from LLM API'})
    end
end

local function handle_openai_non_streaming_response(_, data)
    local response = table.concat(data, '')
    local ok, result = pcall(vim.json.decode, response)
    if ok and result.choices and result.choices[1] and result.choices[1].message then
        show_in_response_buf(vim.split(result.choices[1].message.content, '\n'))
    end
end


local function handle_openai_streaming_response(_, data)
    if #data > 0 then
        for _, line in ipairs(data) do
            api.nvim_buf_set_option(response_buf, 'modifiable', true)
            local lines = vim.split(line, '\n', {})
            for _, l in ipairs(lines) do
                if l ~= '' and l:find('^data: ') then
                    local json_str = l:sub(6) -- Remove 'data: ' prefix
                    json_reconstruct.process_part(json_str, function(complete_json)
                        local success, decoded = pcall(vim.json.decode, complete_json)
                        if success and decoded.choices and decoded.choices[1] and decoded.choices[1].delta and decoded.choices[1].delta.content then
                            append_to_last_line(response_buf, decoded.choices[1].delta.content)
                        end
                    end)
                end
            end
            api.nvim_buf_set_option(response_buf, 'modifiable', false)
        end
    end
end

local function handle_non_streaming_request(_, data)
    local response = table.concat(data, '')
    local ok, result = pcall(vim.json.decode, response)
    if ok and result.message and result.message.content then
        show_in_response_buf(vim.split(result.message.content, '\n'))
    end
end

local function handle_streaming_response(_, data)
    if #data > 0 then
        for _, line in ipairs(data) do
            api.nvim_buf_set_option(response_buf, 'modifiable', true)
            json_reconstruct.process_part(line, function(complete_json)
                local success, decoded = pcall(vim.json.decode, complete_json)
                if success and decoded.message and decoded.message.content then
                    append_to_last_line(response_buf, decoded.message.content)
                end
            end)
            api.nvim_buf_set_option(response_buf, 'modifiable', false)
        end
    end
end

local function handle_openai_request(stream)
    local json_data = vim.json.encode({
        model = config.openai_model,
        messages = messages,
        stream = stream,
        temperature = config.temperature,
        max_tokens = 16384,
    })

    if stream then
        show_in_response_buf({})
    else
        show_in_response_buf({'=== OpenAI Response ===', '', 'Waiting for response...'})
    end

    local headers = {
        'Authorization: Bearer ' .. config.openai_api_key,
        'Content-Type: application/json'
    }

    local handle = (stream and handle_openai_streaming_response) or handle_openai_non_streaming_response
    fn.jobstart({'curl', '-s', '-X', 'POST', config.openai_url, '-H', headers[1], '-H', headers[2], '-d', json_data}, {
        on_stdout = handle,
        on_exit = handle_on_exit,
        stdout_buffered = not stream,
    })
end

local function handle_ollama_request(stream)
    local json_data = vim.json.encode({
        model = config.ollama_model,
        messages = messages,
        stream = stream,
        options = {
            temperature = config.temperature,
            num_ctx = config.context_window_size
        }
    })

    if stream then
        show_in_response_buf({})
    else
        show_in_response_buf({'=== Ollama Response ===', '', 'Waiting for response...'})
    end

    local handle = (stream and handle_streaming_response) or handle_non_streaming_request
    fn.jobstart({'curl', '-s', '-X', 'POST', config.ollama_url, '-d', json_data}, {
        on_stdout = handle,
        on_exit = handle_on_exit,
        stdout_buffered = not stream,
    })
end

-- Generic request handler
local function handle_request(stream)
    local code = utils.get_text(prompt_buf)
    if code == "/clear" then
        Chat.clear_chat()
        return
    elseif code == "/history" then
        Chat.show_history()
        return
    end

    table.insert(messages, {role = "user", content = code})

    if config.api_type == 'openai' then
        handle_openai_request(stream)
    else
        handle_ollama_request(stream)
    end
end

function Chat.setup(main_config)
    config = vim.tbl_extend('force', config, main_config or {})
    -- No specific setup needed for chat beyond config access yet
    vim.keymap.set('v', config.open_prompt_window_key, Chat.open_code_window, { desc = 'Open LLMRequester window' })
    vim.keymap.set('n', config.open_prompt_window_key, Chat.open_code_window, { desc = 'Open LLMRequester window' })
    vim.api.nvim_create_user_command('LLMRequester', Chat.open_code_window, { range = true })
    vim.api.nvim_create_user_command('LLMRequesterSetOllamaModel', Chat.set_ollama_model, { range = true, nargs = 1 })
    vim.api.nvim_create_user_command('LLMRequesterSetOpenaiModel', Chat.set_openai_model, { range = true, nargs = 1 })

    tools.setup()
end

function Chat.send_request()
    handle_request(config.stream)
end

function Chat.set_ollama_model(attr)
    config.ollama_model = attr.fargs[1]
end

function Chat.set_openai_model(attr)
    config.openai_model = attr.fargs[1]
end

function Chat.open_code_window()
    if (prompt_win and api.nvim_win_is_valid(prompt_win)) or 
       (response_win and api.nvim_win_is_valid(response_win)) then
        return
    end

    local selected = ""
    if vim.api.nvim_get_mode().mode:match('[vV]') then
        local old_reg = fn.getreg('z')
        vim.cmd('noautocmd normal! "zy')
        selected = config.prompt .. fn.getreg('z')
        fn.setreg('z', old_reg)
    end

    create_split()
    api.nvim_buf_set_option(prompt_buf, 'modifiable', true)
    api.nvim_buf_set_lines(prompt_buf, 0, -1, false, vim.split(selected, '\n'))
    api.nvim_set_current_win(prompt_win)
end

function Chat.show_history()
    show_in_response_buf({"# History:", ""})
    for i, value in ipairs(messages) do
        local role = value.role
        local content = value.content
        append_to_response_buf({"## " .. role .. ":", ""})
        append_to_response_buf(vim.split(content, '\n'))
    end
end

function Chat.clear_chat()
    messages = {}
    show_in_response_buf({})
end

return Chat
