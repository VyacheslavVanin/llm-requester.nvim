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
    local width = 40
    local height = #content

    -- Create a floating window with the modal dialog content
    local float_win = vim.api.nvim_open_win(bufnr, true, {
        width = width,
        height = height,
        border = 'single',
        relative = 'editor',
        row = (vim.o.lines - height) / 2,
        col = (vim.o.columns - width) / 2
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
end



-- Helper function to set up buffer/window options
local function setup_buffer(win, buf, filetype, modifiable)
    api.nvim_win_set_option(win, 'number', true)
    api.nvim_win_set_option(win, 'relativenumber', false)
    api.nvim_buf_set_option(buf, 'filetype', filetype)
    api.nvim_buf_set_option(buf, 'modifiable', modifiable)
end

-- create Scratch split with command.
-- syntax is optional param (default: 'markdown').
-- returns created win, buf descriptors
function Utils.create_scratch_split(command, mutable, syntax)
    command = command or 'vsplit'
    syntax = syntax or 'markdown'
    mutable = mutable or false
    api.nvim_command(command)
    local win = api.nvim_get_current_win()
    local buf = api.nvim_create_buf(false, true)
    api.nvim_win_set_buf(win, buf)
    setup_buffer(win, buf, syntax, mutable)
    return win, buf
end


-- Helper function to create chat windows
function Utils.create_chat_split(hsplit_ratio, vsplit_ratio)
    local total_width = vim.o.columns
    local total_height = vim.o.lines - 1

    -- Create vertical split for prompt window
    local prompt_win, prompt_buf = Utils.create_scratch_split('vsplit', true)
    -- Create horizontal split for response window
    local response_win, response_buf = Utils.create_scratch_split('split', false)

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

function Utils.scoll_window_end(win_id)
    local orig_win = api.nvim_get_current_win()
    api.nvim_set_current_win(win_id)
    vim.cmd('normal! G')

    api.nvim_set_current_win(orig_win)
end

return Utils
