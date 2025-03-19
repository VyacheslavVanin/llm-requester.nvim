local api = vim.api
local fn = vim.fn

local M = {}

local config = {
    model = 'llama2',
    url = 'http://localhost:11434/api/generate',
    split_ratio = 0.6,
    prompt = 'Please review, improve, and refactor the following code. Provide your suggestions in markdown format with explanations:\n\n',
    open_prompt_window_key = '<leader>ai',
    request_keys = '<leader>r',
    close_keys = '<leader>q',
}

local ns_id = api.nvim_create_namespace('llm_requester')
local left_buf, right_buf
local left_win, right_win

function M.setup(user_config)
    config = vim.tbl_extend('force', config, user_config or {})
end

local function get_visual_selection()
    local buf = vim.api.nvim_get_current_buf()
    local mode = fn.visualmode()
    local start_pos = api.nvim_buf_get_mark(buf, '<')
    local end_pos = api.nvim_buf_get_mark(buf, '>')
    
    -- Convert to 0-based indices
    local start_row = start_pos[1] - 1
    local end_row = end_pos[1]
    
    local lines = api.nvim_buf_get_lines(buf, start_row, end_row, {})
    return table.concat(lines, '\n')
end

local function create_split()
    local width = math.floor(vim.o.columns * config.split_ratio)
    
    api.nvim_command('vsplit')
    left_win = api.nvim_get_current_win()
    left_buf = api.nvim_create_buf(false, true)
    api.nvim_win_set_buf(left_win, left_buf)
    api.nvim_win_set_width(left_win, width)
    
    api.nvim_command('split')
    right_win = api.nvim_get_current_win()
    right_buf = api.nvim_create_buf(false, true)
    api.nvim_win_set_buf(right_win, right_buf)
    
    api.nvim_win_set_option(left_win, 'number', true)
    api.nvim_win_set_option(left_win, 'relativenumber', false)
    api.nvim_buf_set_option(left_buf, 'filetype', 'markdown')
    api.nvim_buf_set_option(left_buf, 'modifiable', true)
    
    api.nvim_win_set_option(right_win, 'number', true)
    api.nvim_win_set_option(right_win, 'relativenumber', false)
    api.nvim_buf_set_option(right_buf, 'filetype', 'markdown')
    api.nvim_buf_set_option(right_buf, 'modifiable', false)
    
    api.nvim_buf_set_keymap(left_buf, 'n', config.request_keys, '', {
        callback = M.send_request,
        desc = 'Send request to Ollama'
    })
    
    api.nvim_buf_set_keymap(left_buf, 'n', config.close_keys, '', {
        callback = function()
            api.nvim_win_close(left_win, true)
            api.nvim_win_close(right_win, true)
        end,
        desc = 'Close Ollama windows'
    })
end

function M.send_request()
    local code = table.concat(api.nvim_buf_get_lines(left_buf, 0, -1, false), '\n')
    local prompt = config.prompt .. code
    
    api.nvim_buf_set_option(right_buf, 'modifiable', true)
    api.nvim_buf_set_lines(right_buf, 0, -1, false, {'=== Ollama Response ===', '', 'Waiting for response...'})
    api.nvim_buf_set_option(right_buf, 'modifiable', false)
    
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
                api.nvim_buf_set_option(right_buf, 'modifiable', true)
                local lines = vim.split(result.response, '\n', {})
                api.nvim_buf_set_lines(right_buf, 2, -1, false, lines)
                api.nvim_buf_set_lines(right_buf, -1, -1, false, {'', '=== Request completed ==='})
                api.nvim_buf_set_option(right_buf, 'modifiable', false)
            end
        end,
        on_exit = function(_, exit_code)
            if exit_code ~= 0 then
                api.nvim_buf_set_option(right_buf, 'modifiable', true)
                api.nvim_buf_set_lines(right_buf, 0, -1, false, {'Error: Failed to get response from Ollama'})
                api.nvim_buf_set_option(right_buf, 'modifiable', false)
            end
        end,
        stdout_buffered = true,  -- Collect all output before processing
    })
end

function M.open_code_window()
    local selected = get_visual_selection()
    create_split()
    
    api.nvim_buf_set_option(left_buf, 'modifiable', true)
    api.nvim_buf_set_lines(left_buf, 0, -1, false, vim.split(selected, '\n', {}))
    
    api.nvim_set_current_win(left_win)
end

vim.api.nvim_create_user_command('LLMRequester', M.open_code_window, { range = true })
vim.keymap.set('v', config.open_prompt_window_key, M.open_code_window, { desc = 'Open LLMRequester window' })

return M

