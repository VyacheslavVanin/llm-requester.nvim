local Utils = {}

local api = vim.api
local fn = vim.fn


-- Get whole buffers text as list of strings. buf = 0 for current buffer
function Utils.get_content(buf)
    return api.nvim_buf_get_lines(buf, 0, -1, false)
end

-- Get whole buffers text as string. buf = 0 for current buffer
function Utils.get_text(buf)
    return table.concat(Utils.get_content(buf), '\n')
end

-- Show content in current buffer exclusivly
function Utils.show_in_buf(buf, content)
    api.nvim_buf_set_option(buf, 'modifiable', true)
    api.nvim_buf_set_lines(buf, 0, -1, false, content)
    api.nvim_buf_set_option(buf, 'modifiable', false)
end

-- Append lines to current buffer
function Utils.append_to_buf(buf, content)
    api.nvim_buf_set_option(buf, 'modifiable', true)
    api.nvim_buf_set_lines(buf, -1, -1, false, content)
    api.nvim_buf_set_option(buf, 'modifiable', false)
end

-- Show content in current buffer exclusivly
function Utils.show_in_buf_mutable(buf, content)
    api.nvim_buf_set_lines(buf, 0, -1, false, content)
end

-- Append lines to current buffer
function Utils.append_to_buf_mutable(buf, content)
    api.nvim_buf_set_lines(buf, -1, -1, false, content)
end

-- Append string to last string if buffer bufnr
function Utils.append_to_last_line(bufnr, text)
    local last_line = vim.api.nvim_buf_line_count(bufnr) - 1  -- lines are 0-indexed
    local current_content = vim.api.nvim_buf_get_lines(bufnr, last_line, last_line + 1, false)[1] or ""
    local inserted_text = vim.split(text, '\n', {})
    inserted_text[1] = current_content .. inserted_text[1]
    vim.api.nvim_buf_set_lines(bufnr, last_line, last_line + 1, false, inserted_text)
end

-- Shows modal window with choices.
-- text - window caption explainig question
-- map - key-action mapping like { y = on_yes, n = on_no}
function Utils.show_choose_window(text, map)
    -- Create a buffer for the modal dialog
    local content = vim.split(text, '\n')
    local bufnr = vim.api.nvim_create_buf(false, true)
    local win_width = vim.o.columns
    local win_height = vim.o.lines
    local width = math.floor(win_width * 0.9)
    local height = #content

    -- Create a floating window with the modal dialog content
    local float_win = vim.api.nvim_open_win(bufnr, true, {
        width = width,
        height = height,
        border = 'single',
        relative = 'editor',
        row = vim.fn.min({
            math.floor((win_height - height) / 2),
            math.floor(win_height / 10)
        }),
        col = (win_width - width) / 2
    })
    api.nvim_win_set_option(float_win, 'number', false)
    api.nvim_win_set_option(float_win, 'relativenumber', false)
    api.nvim_win_set_option(float_win, 'wrap', true)
    -- Set the buffer content
    Utils.show_in_buf(bufnr, content)

    for k, v in pairs(map) do
        local function close_window_wrapper()
            v()
            vim.api.nvim_win_close(float_win, true)
        end
        vim.api.nvim_buf_set_keymap(
            bufnr, '', k, '',
            {
                callback = close_window_wrapper,
                noremap = true,
                silent = true
            }
        )
    end

    -- Focus the floating window
    vim.api.nvim_set_current_win(float_win)
    vim.cmd('stopinsert')
end



-- Helper function to set up buffer/window options
local function setup_buffer(win, buf, filetype, modifiable)
    api.nvim_win_set_option(win, 'number', true)
    api.nvim_win_set_option(win, 'relativenumber', false)
    api.nvim_buf_set_option(buf, 'filetype', filetype)
    api.nvim_buf_set_option(buf, 'modifiable', modifiable)
    api.nvim_buf_set_option(buf, 'wrap', true)
    api.nvim_buf_set_option(buf, 'linebreak', true)
end

-- create Scratch split with command.
-- syntax is optional param (default: 'markdown').
-- returns created win, buf descriptors
function Utils.create_scratch_split(command, mutable, syntax, prev_buf)
    command = command or 'vsplit'
    syntax = syntax or 'markdown'
    mutable = mutable or false
    api.nvim_command(command)
    local win = api.nvim_get_current_win()
    local buf = prev_buf or api.nvim_create_buf(false, true)
    api.nvim_win_set_buf(win, buf)
    if buf ~= prev_buf then
        setup_buffer(win, buf, syntax, mutable)
    end
    return win, buf
end


-- Helper function to create chat windows
function Utils.create_chat_split(hsplit_ratio, vsplit_ratio,
                                 prev_prompt_buf,
                                 prev_response_buf)
    local total_width = vim.o.columns
    local total_height = vim.o.lines - 1

    -- Create vertical split for prompt window
    local prompt_win, prompt_buf = Utils.create_scratch_split(
        'vsplit', true, 'markdown', prev_prompt_buf
    )
    -- Create horizontal split for response window
    local response_win, response_buf = Utils.create_scratch_split(
        'split', false, 'markdown', prev_response_buf
    )

    -- Set dimensions based on ratios
    local prompt_width = math.floor(total_width * hsplit_ratio)
    local prompt_height = math.floor(total_height * vsplit_ratio)
    
    api.nvim_win_set_width(prompt_win, prompt_width)
    api.nvim_win_set_height(prompt_win, prompt_height)
    api.nvim_win_set_height(response_win, total_height - prompt_height)
    api.nvim_set_current_win(prompt_win)
    vim.cmd('startinsert')
    return prompt_win, prompt_buf, response_win, response_buf
end

function Utils.scroll_window_end(win_id)
    local buf = api.nvim_win_get_buf(win_id)
    local lines = api.nvim_buf_line_count(buf)
    api.nvim_win_set_cursor(win_id, {lines, 0})
end

function Utils.is_subdirectory(path, parent)
    -- Check if path contains '..'
    if string.find(path, '%.%.') then
        return false
    end

    -- Allow tools for subdirectories
    if string.sub(path, 1, 1) ~= '/' then
        return true
    end

    -- Ensure both paths start with '/'
    if not (string.sub(path, 1, 1) == '/' and string.sub(parent, 1, 1) == '/') then
        return false
    end

    -- Check if path starts with parent
    if string.sub(path, 1, #parent) == parent then
        return true
    else
        return false
    end
end

return Utils
