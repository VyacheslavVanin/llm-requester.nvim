local api = vim.api
local fn = vim.fn

local Processing = {}

local Utils = require('llm-requester.processing.utils')
local History = require('llm-requester.processing.history')
local GlobalUtils = require('llm-requester.utils')

local is_processing = false

local default_config = {
    openai_model = 'gpt-4o-mini',
    openai_url = 'https://api.openai.com/v1/chat/completions',
    api_key_file = '', -- Path to file containing the API key
    keys = {
        confirm = '<CR>', -- Enter key to confirm
        history_prev = '<C-p>',
        history_next = '<C-n>',
    },
    context_size = 16384, -- maximum context size in tokens
    menu_height = 10,
    menu_width = 50,
    menu_hl = 'NormalFloat',
    menu_border = 'rounded',
    additional_params = {}, -- Additional parameters to pass to chat.completions API
    extended_ctx_num_files = 3, -- Number of additional files to include in the context
    history_file = vim.fn.stdpath('cache') .. '/llm-requester/processing_history.json',
    history_size = 50,
}

local config = default_config -- Store config
local processing_win, processing_buf
local selected_text = {}
local selection_range = {} -- Store the selection range [start_line, end_line]

local history = nil
local prompt_history = {}
local history_index = 0
local history_draft = { '' }
local prompt_title = 'Enter your prompt:'

local function notify(message, level)
    vim.notify('llm-requester: ' .. message, level or vim.log.levels.INFO)
end

local processing_system_message = [[
You are an advanced AI language model designed to process and transform text based on user instructions.
The user will provide you with selected text and a prompt describing what they want you to do with that text.
Process the selected text according to the user's instructions and return only the processed result.
Do not add any explanations or commentary, just return the transformed text.
The selected text is located between BEGIN_SELECTED_TEXT and END_SELECTED_TEXT tags, while instructions are between BEGIN_INSTRUCTIONS and END_INSTRUCTIONS.

You can also use a tool to process the text using a Lua function. To do this, respond with the following format:
BEGIN_TOOL_USE
{
    "tool_name": "apply_function",
    "arguments": {
        "source": "local function process_text(data)\n <<HERE GOES FUNCTION BODY THAT DO WHAT USER WANTS TO DO WITH TEXT>>\n    return result\nend\nreturn process_text"
    }
}
END_TOOL_USE

Use the tool when you need to perform mathematical calculations on values or handle other tasks that require precision.
]]

function Processing.setup(user_config)
    -- Merge user config with defaults, preserving nested structure
    local merged = vim.tbl_deep_extend('force', default_config, user_config or {})
    config = merged
    config.history_file = vim.fn.expand(config.history_file or '')

    history = History.new({
        path = config.history_file,
        limit = config.history_size,
    })

    vim.api.nvim_create_user_command('LLMRequesterProcess', Processing.start_process, { range = true, nargs = '?', force = true })
    vim.api.nvim_create_user_command('LLMRequesterProcessConfirm', Processing.confirm_process, { force = true })
    vim.api.nvim_create_user_command('LLMRequesterProcessHistoryPrev', Processing.history_prev, { force = true })
    vim.api.nvim_create_user_command('LLMRequesterProcessHistoryNext', Processing.history_next, { force = true })
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

local function update_prompt_title()
    if not processing_win or not api.nvim_win_is_valid(processing_win) then
        return
    end

    local title = prompt_title
    if history_index > 0 then
        title = string.format('%s [%d/%d]', prompt_title, history_index, #prompt_history)
    end

    pcall(api.nvim_win_set_config, processing_win, {
        title = title,
        title_pos = 'center',
    })
end

local function show_history(index)
    local lines
    if index <= 0 then
        history_index = 0
        lines = vim.deepcopy(history_draft)
        if #lines == 0 then
            lines = { '' }
        end
    else
        history_index = index
        lines = vim.split(prompt_history[index], '\n', { plain = true })
    end

    vim.api.nvim_buf_set_lines(processing_buf, 0, -1, false, lines)

    if processing_win and api.nvim_win_is_valid(processing_win) then
        local last_line = #lines
        api.nvim_win_set_cursor(processing_win, { last_line, #(lines[last_line] or '') })
    end

    update_prompt_title()
end

local function cycle_history(direction)
    if not is_processing then
        return
    end
    if not processing_buf or not api.nvim_buf_is_valid(processing_buf) then
        return
    end
    if #prompt_history == 0 then
        notify('processing prompt history is empty')
        return
    end

    if history_index == 0 then
        history_draft = api.nvim_buf_get_lines(processing_buf, 0, -1, false)
    end

    local next_index = History.cycle_index(history_index, #prompt_history, direction)
    show_history(next_index)
end

---Shows the previous (older) processing prompt.
function Processing.history_prev()
    cycle_history('older')
end

---Shows the next (newer) processing prompt.
function Processing.history_next()
    cycle_history('newer')
end

---Closes the processing prompt without applying anything.
function Processing.cancel()
    if processing_win and api.nvim_win_is_valid(processing_win) then
        api.nvim_win_close(processing_win, true)
    end
    is_processing = false
end

local function set_history_keymaps()
    local keys = config.keys or {}

    local function map(lhs, direction, description)
        if type(lhs) ~= 'string' or lhs == '' then
            return
        end
        for _, mode in ipairs({ 'i', 'n' }) do
            api.nvim_buf_set_keymap(processing_buf, mode, lhs, '', {
                callback = function()
                    cycle_history(direction)
                end,
                noremap = true,
                silent = true,
                desc = description,
            })
        end
    end

    map(keys.history_prev, 'older', 'Previous processing prompt')
    map(keys.history_next, 'newer', 'Next processing prompt')
end

function Processing.start_process(opts)
    if is_processing then
        return
    end
    is_processing = true

    local args = (opts and opts.args) or ''

    -- Get the selected text using the visual selection range
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    local start_line = start_pos[2]
    local end_line = end_pos[2]
 
    -- Store the selection range for later use
    selection_range = {start_line, end_line}
 
    selected_text = Processing.get_selected_text(start_line, end_line)

    if history then
        local _, load_err = history:load()
        if load_err then
            notify('failed to load processing prompt history: ' .. load_err, vim.log.levels.WARN)
        end
        prompt_history = history:entries()
    else
        prompt_history = {}
    end
    history_index = 0

    -- Create a buffer for the prompt input
    processing_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(processing_buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(processing_buf, 'bufhidden', 'wipe')
    vim.api.nvim_buf_set_option(processing_buf, 'swapfile', false)
    vim.api.nvim_buf_set_option(processing_buf, 'undolevels', -1) -- Disable undo
    vim.api.nvim_buf_set_option(processing_buf, 'filetype', 'prompt')

    -- Set initial content to guide the user
    local prompt = args ~= '' and { args } or { '' }
    history_draft = vim.deepcopy(prompt)
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
        title = 'Enter your prompt:',
        title_pos = 'center',
    })

    vim.api.nvim_win_set_option(processing_win, 'winhl', 'Normal:' .. config.menu_hl)
    if vim.o.termguicolors then
        vim.api.nvim_win_set_option(processing_win, 'winblend', 10)
    end

    -- Set up key mappings
    local confirm = function()
        Processing.confirm_process()
    end
 
    local cancel = function()
        Processing.cancel()
    end

    -- Clear existing mappings if they exist and set new ones
    pcall(vim.api.nvim_buf_del_keymap, processing_buf, 'n', '<CR>')
    pcall(vim.api.nvim_buf_del_keymap, processing_buf, 'n', '<Esc>')
 
    vim.api.nvim_buf_set_keymap(processing_buf, 'n', '<CR>', '', { callback = confirm, noremap = true })
    vim.api.nvim_buf_set_keymap(processing_buf, 'n', '<Esc>', '', { callback = cancel, noremap = true })
    set_history_keymaps()
    update_prompt_title()

    -- Enter insert mode in the prompt buffer
    vim.api.nvim_set_current_buf(processing_buf)
    if args == '' then
        vim.cmd('startinsert')
    end
end

function Processing.confirm_process()
    if not is_processing then
        return
    end

    -- Get the prompt from the buffer (everything before the separator line)
    local all_lines = vim.api.nvim_buf_get_lines(processing_buf, 0, -1, false)
    local prompt = table.concat(all_lines, '\n'):gsub('^%s+', ''):gsub('%s+$', '') -- trim whitespace
    local history_prompt = prompt

    -- Check for /no_extended_context tag
    local extended_ctx = GlobalUtils.get_extended_completion_context(config.extended_ctx_num_files)
    if prompt:find("/no_extended_context") then
        extended_ctx = nil
        prompt = prompt:gsub("/no_extended_context", ""):gsub("^%s+", ""):gsub("%s+$", "")
    end

    if history and history_prompt ~= '' then
        local saved, save_err = history:add(history_prompt)
        if not saved then
            notify('failed to save processing prompt history: ' .. tostring(save_err), vim.log.levels.WARN)
        end
    end

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
    if vim.o.termguicolors then
        vim.api.nvim_win_set_option(result_win, 'winblend', 10)
    end

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
    Utils.handle_openai_request(processing_system_message, context, extended_ctx, result_buf, result_win, config, finish_processing)
end

return Processing
