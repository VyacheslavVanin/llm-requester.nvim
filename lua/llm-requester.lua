local api = vim.api
local fn = vim.fn

local M = {}

local config = {
    model = 'llama2',
    completion_model = 'llama2', -- Added separate model for completion
    url = 'http://localhost:11434/api/chat',
    split_ratio = 0.6,
    prompt_split_ratio = 0.2, -- parameter to control dimensions of prompt and response windows
    prompt = 'Please review, improve, and refactor the following code. Provide your suggestions in markdown format with explanations:\n\n',
    open_prompt_window_key = '<leader>ai',
    request_keys = '<leader>r',
    close_keys = '<leader>q',
    stream = false,
    completion_keys = {
        trigger = '<C-Tab>',
        confirm = '<Tab>',
    },
    completion_context_lines = 3, -- number of lines before/after cursor to use as context
    completion_menu_height = 10,
    completion_menu_width = 50,
    completion_menu_hl = 'NormalFloat',
    completion_menu_border = 'rounded',
}

local completion_system_message = [[
You are an advanced AI language model designed to provide intelligent and contextually relevant assistance. Your primary function is to understand the user's intent behind their queries or requests, and then deliver precise continuation to user's code.

To achieve this, consider the following guidelines:

Understand the user's intent and provide relevant, concise code completion suggestions in plain text format.
Your task is to simulate a smart code completion system that provides correct code snippets.
NEVER enclose you response in markdown code tags.
ALWAYS Reply with just code that shoulld follow the user code, without explanations, comments, markdown, and other words other just program snippet because your output will be added to the user's program and it should work.
]]

local ns_id = api.nvim_create_namespace('llm_requester')
local prompt_buf, response_buf
local prompt_win, response_win
local completion_win, completion_buf

local function setup_completion()
    vim.api.nvim_create_autocmd('BufEnter', {
        callback = function()
            local buf = vim.api.nvim_get_current_buf()
            vim.keymap.set('i', config.completion_keys.trigger, function()
                M.show_completion()
                return ''
            end, { buffer = buf, expr = true })
        end
    })
end

function M.setup(user_config)
    config = vim.tbl_extend('force', config, user_config or {})
    setup_completion()
end

function M.show_completion()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = cursor[1] - 1
    local lines = vim.api.nvim_buf_get_lines(0, 
        math.max(0, line - config.completion_context_lines), 
        line + config.completion_context_lines + 1, 
        false)
    local context = table.concat(lines, '\n')

    completion_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(completion_buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(completion_buf, 'bufhidden', 'wipe')
    vim.api.nvim_buf_set_option(completion_buf, 'swapfile', false)
    vim.api.nvim_buf_set_option(completion_buf, 'undolevels', -1) -- Disable undo

    completion_win = vim.api.nvim_open_win(completion_buf, true, {
        relative = 'cursor',
        style = 'minimal',
        width = config.completion_menu_width,
        height = 1, -- Start with 1 line for loading message
        row = 1,
        col = 0,
        border = config.completion_menu_border,
        focusable = true,
        zindex = 100,
    })
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', true
    )

    vim.api.nvim_win_set_option(completion_win, 'winhl', 'Normal:' .. config.completion_menu_hl)
    vim.api.nvim_win_set_option(completion_win, 'winblend', 10)

    -- Setup key mappings before API call
    local keys = {
        [config.completion_keys.confirm] = function()
            local selection = api.nvim_buf_get_lines(completion_buf, 0, -1, false)
            vim.api.nvim_win_close(completion_win, true)
            -- Insert text and restore insert mode if needed
            local row, col = unpack(vim.api.nvim_win_get_cursor(0))
            vim.api.nvim_put(selection, 'c', true, true)
            return ''
        end,
        __default = function()
            vim.api.nvim_win_close(completion_win, true)
            return vim.api.nvim_replace_termcodes('<Ignore>', true, false, true)
        end,
    }

    -- Set key mappings in normal mode only with proper options
    api.nvim_buf_set_keymap(completion_buf, 'n', '<Esc>', '', { callback = keys.__default })
    api.nvim_buf_set_keymap(completion_buf, 'n', config.completion_keys.confirm, '', { callback = keys[config.completion_keys.confirm] })

    local json_data = vim.json.encode({
        model = config.completion_model,
        messages = {
            {
                role = "system",
                content = completion_system_message
            },
            {
                role = "user",
                content = context
            }
        },
        stream = false,
        options = { temperature = 0.2 }
    })

    fn.jobstart({'curl', '-s', '-X', 'POST', config.url, '-d', json_data}, {
        on_stdout = function(_, data)
            local response = table.concat(data, '')
            local ok, result = pcall(vim.json.decode, response)
            if ok and result.message and result.message.content then
                local suggestions = {}
                for line in vim.gsplit(result.message.content, '\n') do
                    if line ~= '' then
                        table.insert(suggestions, line)
                    end
                end
                vim.schedule(function()
                    if vim.api.nvim_win_is_valid(completion_win) then
                        vim.api.nvim_buf_set_lines(completion_buf, 0, -1, false, suggestions)
                        vim.api.nvim_win_set_height(completion_win, 
                            math.min(#suggestions, config.completion_menu_height))
                        api.nvim_buf_set_option(completion_buf, 'modifiable', false)
                    end
                end)
            end
        end,
        on_exit = function(_, code)
            if code ~= 0 then
                vim.schedule(function()
                    if vim.api.nvim_win_is_valid(completion_win) then
                        vim.api.nvim_buf_set_lines(completion_buf, 0, -1, false, 
                            {'Error getting completions'})
                        api.nvim_buf_set_option(completion_buf, 'modifiable', false)
                    end
                end)
            end
        end
    })
end

-- Helper function to set up buffer/window options
local function setup_buffer(win, buf, filetype, modifiable)
    api.nvim_win_set_option(win, 'number', true)
    api.nvim_win_set_option(win, 'relativenumber', false)
    api.nvim_buf_set_option(buf, 'filetype', filetype)
    api.nvim_buf_set_option(buf, 'modifiable', modifiable)
end

-- Helper function to create windows
local function create_split()
    local total_width = vim.o.columns
    local total_height = vim.o.lines - 1

    -- Create vertical split for prompt window
    api.nvim_command('vsplit')
    prompt_win = api.nvim_get_current_win()
    prompt_buf = api.nvim_create_buf(false, true)
    api.nvim_win_set_buf(prompt_win, prompt_buf)
    setup_buffer(prompt_win, prompt_buf, 'markdown', true)

    -- Create horizontal split for response window
    api.nvim_command('split')
    response_win = api.nvim_get_current_win()
    response_buf = api.nvim_create_buf(false, true)
    api.nvim_win_set_buf(response_win, response_buf)
    setup_buffer(response_win, response_buf, 'markdown', false)

    -- Set dimensions based on ratios
    local prompt_width = math.floor(total_width * config.split_ratio)
    local prompt_height = math.floor(total_height * config.prompt_split_ratio)
    
    api.nvim_win_set_width(prompt_win, prompt_width)
    api.nvim_win_set_height(prompt_win, prompt_height)
    api.nvim_win_set_height(response_win, total_height - prompt_height)

    -- Set keymaps
    local close_func = function() 
        if api.nvim_win_is_valid(prompt_win) then api.nvim_win_close(prompt_win, true) end
        if api.nvim_win_is_valid(response_win) then api.nvim_win_close(response_win, true) end
    end

    api.nvim_buf_set_keymap(prompt_buf, 'n', config.request_keys, '', { callback = M.send_request })
    api.nvim_buf_set_keymap(prompt_buf, 'n', config.close_keys, '', { callback = close_func })
    api.nvim_buf_set_keymap(response_buf, 'n', config.close_keys, '', { callback = close_func })
end

-- Generic request handler
local function handle_request(stream)
    local code = table.concat(api.nvim_buf_get_lines(prompt_buf, 0, -1, false), '\n')
    local json_data = vim.json.encode({
        model = config.model,
        messages = {
            {
                role = "user",
                content = code
            }
        },
        stream = stream,
        options = { temperature = 0.5 }
    })

    api.nvim_buf_set_option(response_buf, 'modifiable', true)
    api.nvim_buf_set_lines(response_buf, 0, -1, false, {'=== Ollama Response ===', '', 'Waiting for response...'})
    api.nvim_buf_set_option(response_buf, 'modifiable', false)

    local handle = (stream and M.handle_streaming_response) or M.handle_non_streaming_request
    fn.jobstart({'curl', '-s', '-X', 'POST', config.url, '-d', json_data}, {
        on_stdout = handle,
        on_exit = handle_on_exit,
        stdout_buffered = not stream,
    })
end

function M.send_request()
    handle_request(config.stream)
end

local function handle_on_exit(_, exit_code)
    if exit_code ~= 0 then
        api.nvim_buf_set_option(response_buf, 'modifiable', true)
        api.nvim_buf_set_lines(response_buf, 0, -1, false, {'Error: Failed to get response from Ollama'})
        api.nvim_buf_set_option(response_buf, 'modifiable', false)
    end
end

function M.handle_non_streaming_request(_, data)
    local response = table.concat(data, '')
    local ok, result = pcall(vim.json.decode, response)
    if ok and result.message and result.message.content then
        api.nvim_buf_set_option(response_buf, 'modifiable', true)
        api.nvim_buf_set_lines(response_buf, 2, -1, false, vim.split(result.message.content, '\n'))
        api.nvim_buf_set_lines(response_buf, -1, -1, false, {'', '=== Request completed ==='})
        api.nvim_buf_set_option(response_buf, 'modifiable', false)
    end
end

function M.handle_streaming_response(_, data)
    if #data > 0 then
        for _, line in ipairs(data) do
            api.nvim_buf_set_option(response_buf, 'modifiable', true)
            local lines = vim.split(line, '\n', {})
            for _, l in ipairs(lines) do
                if l ~= '' then
                    local success, decoded = pcall(vim.json.decode, l)
                    if success and decoded.message and decoded.message.content then
                        api.nvim_buf_call(response_buf, function()
                            api.nvim_put(vim.split(decoded.message.content, '\n'), 'c', false, true)
                        end)
                    end
                end
            end
            api.nvim_buf_set_option(response_buf, 'modifiable', false)
        end
    end
end

function M.open_code_window()
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

vim.api.nvim_create_user_command('LLMRequester', M.open_code_window, { range = true })
vim.keymap.set('v', config.open_prompt_window_key, M.open_code_window, { desc = 'Open LLMRequester window' })
vim.keymap.set('n', config.open_prompt_window_key, M.open_code_window, { desc = 'Open LLMRequester window' })

return M
