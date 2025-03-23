local api = vim.api
local fn = vim.fn

local M = {}

local config = {
    model = 'llama2',
    url = 'http://localhost:11434/api/generate',
    split_ratio = 0.6,
    prompt_split_ratio = 0.2, -- parameter to control dimensions of prompt and response windows
    prompt = 'Please review, improve, and refactor the following code. Provide your suggestions in markdown format with explanations:\n\n',
    open_prompt_window_key = '<leader>ai',
    request_keys = '<leader>r',
    close_keys = '<leader>q',
    stream = false,
}

local ns_id = api.nvim_create_namespace('llm_requester')
local prompt_buf, response_buf
local prompt_win, response_win

function M.setup(user_config)
    config = vim.tbl_extend('force', config, user_config or {})
end

local function create_split()
    local prompt_width = math.floor(vim.o.columns * config.prompt_split_ratio)
    local response_width = vim.o.columns - prompt_width
    
    api.nvim_command('vsplit')
    prompt_win = api.nvim_get_current_win()
    prompt_buf = api.nvim_create_buf(false, true)
    api.nvim_win_set_buf(prompt_win, prompt_buf)

    api.nvim_command('split')
    response_win = api.nvim_get_current_win()
    response_buf = api.nvim_create_buf(false, true)
    api.nvim_win_set_buf(response_win, response_buf)

    -- Set height based on prompt_split_ratio
    local total_height = vim.o.lines - 1
    local prompt_height = math.floor(total_height * config.prompt_split_ratio)
    local response_height = total_height - prompt_height

    api.nvim_win_set_height(prompt_win, prompt_height)
    api.nvim_win_set_height(response_win, response_height)
    
    api.nvim_win_set_option(prompt_win, 'number', true)
    api.nvim_win_set_option(prompt_win, 'relativenumber', false)
    api.nvim_buf_set_option(prompt_buf, 'filetype', 'markdown')
    api.nvim_buf_set_option(prompt_buf, 'modifiable', true)
    
    api.nvim_win_set_option(response_win, 'number', true)
    api.nvim_win_set_option(response_win, 'relativenumber', false)
    api.nvim_buf_set_option(response_buf, 'filetype', 'markdown')
    api.nvim_buf_set_option(response_buf, 'modifiable', false)
    
    api.nvim_buf_set_keymap(prompt_buf, 'n', config.request_keys, '', {
        callback = M.send_request,
    })

    function close_windows()
        api.nvim_win_close(prompt_win, true)
        api.nvim_win_close(response_win, true)
    end

    api.nvim_buf_set_keymap(prompt_buf, 'n', config.close_keys, '', {
        callback = close_windows,
        desc = 'Close Ollama windows'
    })

    api.nvim_buf_set_keymap(response_buf, 'n', config.close_keys, '', {
        callback = close_windows,
        desc = 'Close Ollama windows'
    })
end

function M.send_request()
    if config.stream then
        M.send_streaming_request()
        return
    end
    local code = table.concat(api.nvim_buf_get_lines(prompt_buf, 0, -1, false), '\n')
    local prompt = code
    
    api.nvim_buf_set_option(response_buf, 'modifiable', true)
    api.nvim_buf_set_lines(response_buf, 0, -1, false, {'=== Ollama Response ===', '', 'Waiting for response...'})
    api.nvim_buf_set_option(response_buf, 'modifiable', false)
    
    local json_data = vim.json.encode({
        model = config.model,
        prompt = prompt,
        stream = false,  -- Disable streaming
        options = { temperature = 0.5 }
    })
    
    local job_id = fn.jobstart({'curl', '-s', '-X', 'POST', config.url, '-d', json_data}, {
        on_stdout = function(_, data, _)
            local response = table.concat(data, '')
            local ok, result = pcall(vim.json.decode, response)
            if ok and result.response then
                api.nvim_buf_set_option(response_buf, 'modifiable', true)
                local lines = vim.split(result.response, '\n', {})
                api.nvim_buf_set_lines(response_buf, 2, -1, false, lines)
                api.nvim_buf_set_lines(response_buf, -1, -1, false, {'', '=== Request completed ==='})
                api.nvim_buf_set_option(response_buf, 'modifiable', false)
            end
        end,
        on_exit = function(_, exit_code)
            if exit_code ~= 0 then
                api.nvim_buf_set_option(response_buf, 'modifiable', true)
                api.nvim_buf_set_lines(response_buf, 0, -1, false, {'Error: Failed to get response from Ollama'})
                api.nvim_buf_set_option(response_buf, 'modifiable', false)
            end
        end,
        stdout_buffered = true,  -- Collect all output before processing
    })
end

local function handle_response_and_extract_token(data)
    if #data > 0 then
        for _, line in ipairs(data) do
            api.nvim_buf_set_option(response_buf, 'modifiable', true)
            local lines = vim.split(line, '\n', {})
            for _, l in ipairs(lines) do
                if l ~= '' then
                    local success, decoded = pcall(vim.json.decode, l)
                    if success and decoded.response then
                        api.nvim_buf_call(response_buf, function()
                            api.nvim_put(vim.split(decoded.response, '\n'), 'c', false, true)
                        end)
                    end
                end
            end
            api.nvim_buf_set_option(response_buf, 'modifiable', false)
        end
    end
end

function M.send_streaming_request()
    local code = table.concat(api.nvim_buf_get_lines(prompt_buf, 0, -1, false), '\n')
    local prompt = code
    
    api.nvim_buf_set_option(response_buf, 'modifiable', true)
    api.nvim_buf_set_lines(response_buf, 0, -1, false, {'=== Ollama Response ===', '', 'Waiting for response...'})
    api.nvim_buf_set_option(response_buf, 'modifiable', false)
    
    local json_data = vim.json.encode({
        model = config.model,
        prompt = prompt,
        stream = true,  -- Enable streaming
        options = { temperature = 0.5 }
    })
    
    local job_id = fn.jobstart({'curl', '-s', '-X', 'POST', config.url, '-d', json_data}, {
        on_stdout = function(_, data, _)
            handle_response_and_extract_token(data)
        end,
        on_exit = function(_, exit_code)
            if exit_code ~= 0 then
                api.nvim_buf_set_option(response_buf, 'modifiable', true)
                api.nvim_buf_set_lines(response_buf, -1, -1, false, {'Error: Failed to get response from Ollama'})
                api.nvim_buf_set_option(response_buf, 'modifiable', false)
            end
        end,
        stdout_buffered = false,  -- Process output as it arrives
    })
end

function M.open_code_window()
    -- Check if existing windows are still open
    if (prompt_win and vim.api.nvim_win_is_valid(prompt_win)) or 
        (response_win and vim.api.nvim_win_is_valid(response_win)) then
         return  -- Exit if windows are already open
    end

    local selected = ""
    local current_mode = vim.api.nvim_get_mode().mode
    if current_mode:match('[vV]') then
        -- Use yank-based selection to avoid mark issues
        local old_reg = vim.fn.getreg('z')  -- Save register 'z'
        vim.cmd('noautocmd normal! "zy')  -- Yank last visual selection
        selected = config.prompt .. vim.fn.getreg('z')
        vim.fn.setreg('z', old_reg)  -- Restore register 'z'
    end

    create_split()
    api.nvim_buf_set_option(prompt_buf, 'modifiable', true)
    api.nvim_buf_set_lines(prompt_buf, 0, -1, false, vim.split(selected, '\n', {}))
    
    api.nvim_set_current_win(prompt_win)
end

vim.api.nvim_create_user_command('LLMRequester', M.open_code_window, { range = true })
vim.keymap.set('v', config.open_prompt_window_key, M.open_code_window, { desc = 'Open LLMRequester window' })
vim.keymap.set('n', config.open_prompt_window_key, M.open_code_window, { desc = 'Open LLMRequester window' })

return M
