local api = vim.api
local fn = vim.fn

local Processing = {}

local Utils = require('llm-requester.processing.utils')

local is_processing = false

local default_config = {
    openai_model = 'gpt-4o-mini',
    openai_url = 'https://api.openai.com/v1/chat/completions',
    api_key_file = '', -- Path to file containing the API key
    keys = {
        confirm = '<CR>', -- Enter key to confirm
    },
    context_size = 16384, -- maximum context size in tokens
    menu_height = 10,
    menu_width = 50,
    menu_hl = 'NormalFloat',
    menu_border = 'rounded',
}

local config = default_config -- Store config
local processing_win, processing_buf
local selected_text = {}
local selection_range = {} -- Store the selection range [start_line, end_line]

local processing_system_message = [[
You are an advanced AI language model designed to process and transform text based on user instructions.
The user will provide you with selected text and a prompt describing what they want you to do with that text.
Process the selected text according to the user's instructions and return only the processed result.
Do not add any explanations or commentary, just return the transformed text.
The selected text is located between BEGIN_SELECTED_TEXT and END_SELECTED_TEXT tags, while instructions are between BEGIN_INSTRUCTIONS and END_INSTRUCTIONS.
]]

function Processing.setup(user_config)
    -- Merge user config with defaults, preserving nested structure
    local merged = vim.tbl_deep_extend('force', default_config, user_config or {})
    config = merged

    vim.api.nvim_create_user_command('LLMRequesterProcess', Processing.start_process, { range = true, nargs = '?' })
    vim.api.nvim_create_user_command('LLMRequesterProcessConfirm', Processing.confirm_process, {})
end

-- Get the selected text based on the range provided by the user command
function Processing.get_selected_text(start_line, end_line)
    -- Adjust for 0-based indexing
    start_line = start_line - 1
    end_line = end_line - 1
 
    -- Get the selected lines
    local lines = vim.api.nvim_buf_get_lines(0, start_line, end_line + 1, {})
 
    return lines
end

function Processing.start_process(opts)
    if is_processing then
        return
    end
    is_processing = true

    -- Get the selected text using the visual selection range
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    local start_line = start_pos[2]
    local end_line = end_pos[2]
 
    -- Store the selection range for later use
    selection_range = {start_line, end_line}
 
    selected_text = Processing.get_selected_text(start_line, end_line)
 
    -- Create a buffer for the prompt input
    processing_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(processing_buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(processing_buf, 'bufhidden', 'wipe')
    vim.api.nvim_buf_set_option(processing_buf, 'swapfile', false)
    vim.api.nvim_buf_set_option(processing_buf, 'undolevels', -1) -- Disable undo
    vim.api.nvim_buf_set_option(processing_buf, 'filetype', 'prompt')

    -- Set initial content to guide the user
    local user_prompt = (opts and opts.args ~= "" and {opts.args}) or {
        '',
        '',
    }
    local prompt = user_prompt
    vim.list_extend(prompt, {'', '-- Selected text --' })
    -- Add each line of selected text individually
    for _, line in ipairs(selected_text) do
        table.insert(prompt, line)
    end
    vim.api.nvim_buf_set_lines(processing_buf, 0, -1, false, prompt)

    -- Open a floating window for the prompt
    local width = config.menu_width
    local height = config.menu_height
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    processing_win = vim.api.nvim_open_win(processing_buf, true, {
        relative = 'editor',
        style = 'minimal',
        width = width,
        height = height,
        row = row,
        col = col,
        border = config.menu_border,
        focusable = true,
        zindex = 100,
    })

    vim.api.nvim_win_set_option(processing_win, 'winhl', 'Normal:' .. config.menu_hl)
    vim.api.nvim_win_set_option(processing_win, 'winblend', 10)

    -- Set up key mappings
    local confirm = function()
        Processing.confirm_process()
    end
 
    local cancel = function()
        vim.api.nvim_win_close(processing_win, true)
        is_processing = false
    end

    -- Clear existing mappings if they exist and set new ones
    pcall(vim.api.nvim_buf_del_keymap, processing_buf, 'n', '<CR>')
    pcall(vim.api.nvim_buf_del_keymap, processing_buf, 'n', '<Esc>')
 
    vim.api.nvim_buf_set_keymap(processing_buf, 'n', '<CR>', '', { callback = confirm, noremap = true })
    vim.api.nvim_buf_set_keymap(processing_buf, 'n', '<Esc>', '', { callback = cancel, noremap = true })

    -- Enter insert mode in the prompt buffer
    vim.api.nvim_set_current_buf(processing_buf)
    if opts.args == "" then
        vim.cmd('startinsert')
    end
end

function Processing.confirm_process()
    if not is_processing then
        return
    end

    -- Get the prompt from the buffer (everything before the separator line)
    local all_lines = vim.api.nvim_buf_get_lines(processing_buf, 0, -1, false)
 
    -- Find the separator line index
    local separator_idx = nil
    for i, line in ipairs(all_lines) do
        if line == '-- Selected text --' then
            separator_idx = i
            break
        end
    end
 
    -- Extract prompt lines (everything before the separator)
    local prompt_lines = {}
    if separator_idx then
        for i = 1, separator_idx - 1 do
            table.insert(prompt_lines, all_lines[i])
        end
    else
        -- If no separator found, use all lines
        prompt_lines = all_lines
    end
 
    -- The prompt is the concatenated prompt lines
    local prompt = table.concat(prompt_lines, '\n'):gsub('^%s+', ''):gsub('%s+$', '') -- trim whitespace
 
    -- Close the prompt window
    vim.api.nvim_win_close(processing_win, true)
 
    -- Prepare the context for the API call
    local context = 'BEGIN_SELECTED_TEXT\n' .. table.concat(selected_text, '\n') .. '\nEND_SELECTED_TEXT\n\nBEGIN_INSTRUCTIONS\n' .. prompt .. '\nEND_INSTRUCTIONS'
 
    -- Create a temporary buffer to show the processing result
    local result_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(result_buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(result_buf, 'bufhidden', 'wipe')
    vim.api.nvim_buf_set_option(result_buf, 'swapfile', false)
    vim.api.nvim_buf_set_option(result_buf, 'undolevels', -1) -- Disable undo
    vim.api.nvim_buf_set_option(result_buf, 'modifiable', true)

    -- Set initial content to show loading
    vim.api.nvim_buf_set_lines(result_buf, 0, -1, false, { 'Processing...', '' })

    -- Open a floating window for the result
    local width = config.menu_width
    local height = config.menu_height
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local result_win = vim.api.nvim_open_win(result_buf, true, {
        relative = 'editor',
        style = 'minimal',
        width = width,
        height = 1, -- Start with 1 line for loading message
        row = row,
        col = col,
        border = config.menu_border,
        focusable = true,
        zindex = 100,
    })

    vim.api.nvim_win_set_option(result_win, 'winhl', 'Normal:' .. config.menu_hl)
    vim.api.nvim_win_set_option(result_win, 'winblend', 10)

    local finish_processing = function()
        vim.api.nvim_win_close(result_win, true)
        is_processing = false
    end

    -- Set up key mappings for the result window
    local confirm_result = function()
        -- Get the result from the buffer
        local result_lines = vim.api.nvim_buf_get_lines(result_buf, 0, -1, false)
  
        -- Remove the "Processing..." line if it's still there
        if #result_lines == 1 and result_lines[1] == 'Processing...' then
            finish_processing()
            return
        end
  
        -- Close the result window
        vim.api.nvim_win_close(result_win, true)
  
        -- Replace the selected text with the result using stored selection range
        local start_line = selection_range[1] - 1  -- Get start of visual selection (0-indexed)
        local end_line = selection_range[2] - 1    -- Get end of visual selection (0-indexed)

        -- Replace the selected lines with the result
        vim.api.nvim_buf_set_lines(0, start_line, end_line + 1, false, result_lines)
  
        is_processing = false
    end

    local cancel_result = function()
        vim.api.nvim_win_close(result_win, true)
        is_processing = false
    end

    -- Set key mappings for the result window
    vim.api.nvim_buf_set_keymap(result_buf, 'n', '<CR>', '', { callback = confirm_result, noremap = true })
    vim.api.nvim_buf_set_keymap(result_buf, 'n', '<Esc>', '', { callback = cancel_result, noremap = true })

    -- Make the result window non-modifiable after setting content
    vim.api.nvim_buf_set_option(result_buf, 'modifiable', false)

    -- Call the API to process the text
    Utils.handle_openai_request(processing_system_message, context, result_buf, result_win, config, finish_processing)
end

return Processing
