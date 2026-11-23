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
    local inserted_text = vim.split(text, '\n', { plain = true })
    inserted_text[1] = current_content .. inserted_text[1]
    vim.api.nvim_buf_set_lines(bufnr, last_line, last_line + 1, false, inserted_text)
end

-- Helper function to set up buffer/window options
local function setup_buffer(win, buf, filetype, modifiable)
    api.nvim_win_set_option(win, 'number', true)
    api.nvim_win_set_option(win, 'relativenumber', false)
    api.nvim_win_set_option(win, 'wrap', true)
    api.nvim_win_set_option(win, 'linebreak', true)
    api.nvim_buf_set_option(buf, 'filetype', filetype)
    api.nvim_buf_set_option(buf, 'modifiable', modifiable)
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

function Utils.get_first_filename_from_buffers()
    -- Get the current tab page number
    local tabnr = vim.api.nvim_get_current_tabpage()

    -- Get the list of buffers in the current tab page
    local windows = vim.api.nvim_tabpage_list_wins(tabnr)

    -- Iterate through the buffers and find the first real file
    for _, win_id in ipairs(windows) do
        local bufnr = vim.api.nvim_win_get_buf(win_id)
        local filename = vim.api.nvim_buf_get_name(bufnr)
        if filename ~= "" and vim.fn.filereadable(filename) == 1 then
            return filename
        end
    end

    -- Return nil if no buffer with a valid filename is found
    return nil
end

-- Function to read API key from file
function Utils.read_api_key_from_file(file_path)
    if file_path == nil or file_path == '' then
        return nil
    end

    local file = io.open(file_path, 'r')
    if file then
        local api_key = file:read('*a'):gsub('%s+', '') -- Read all content and remove whitespace
        file:close()
        return api_key
    else
        vim.notify('Could not read API key file: ' .. file_path, vim.log.levels.WARN)
        return nil
    end
end

-- Returns a full chat-completions endpoint. Accepts both a base URL
-- (https://api.openai.com/v1) and an already complete URL.
function Utils.completions_url(base_url)
    if base_url == nil or base_url == '' then
        return ''
    end

    local url = tostring(base_url):gsub('/+$', '')
    if url:match('/chat/completions$') then
        return url
    end

    return url .. '/chat/completions'
end

-- Get buffer file name.
-- If buffer is not file then return nil
function Utils.get_buffer_filename(bufnr)
    local filename = vim.api.nvim_buf_get_name(bufnr)
    if filename == nil or filename == "" or not vim.fn.filereadable(filename) then
        return nil
    end
    return filename
end

-- Get last N opened filenames within the current session with last cursor positions
-- filename must be check is it realy an existing file
function Utils.get_last_opened_buffers(n)
    local all_buffers = vim.api.nvim_list_bufs()
    local result = {}
    for _, bufnr in ipairs(all_buffers) do
        local filename = Utils.get_buffer_filename(bufnr)
        local basename = vim.fn.fnamemodify(filename, ':t')
        if filename and vim.fn.filereadable(filename) == 1 and not basename:match("^%.") then
            local cursor = vim.api.nvim_buf_get_mark(bufnr, '"')
            local size = vim.fn.getfsize(filename)
            table.insert(result, {
                filename = filename,
                cursor = cursor,
                size = size
            })
        end
    end
    -- Sort by changedtick descending to get the most recently modified/active ones
    table.sort(result, function(a, b)
        local a_tick = vim.api.nvim_buf_get_changedtick(vim.fn.bufnr(a.filename))
        local b_tick = vim.api.nvim_buf_get_changedtick(vim.fn.bufnr(b.filename))
        return a_tick > b_tick
    end)
    local count = math.min(n, #result)
    return vim.list_slice(result, 1, count)
end

-- Retrieve extended completion context.
-- if number_of_files_to_include is nil or 0 then returns nil.
-- Otherwise return the result as a formatted string:
-- # Additional Context:
-- ## User Editing This File:
-- <current buffer file name>
--
-- ## User's Last Viewed Files:
-- ### some_file_name.cpp
-- ```<content of some_file_name.cpp>```
--
-- ### some_other_file_name.hpp
-- ```<content of some_other_file_name.hpp>```
function Utils.get_extended_completion_context(number_of_files_to_include)
    if not number_of_files_to_include or number_of_files_to_include == 0 then
        return nil
    end

    local context_lines = {}
    table.insert(context_lines, "# Additional context:")
    table.insert(context_lines, "## User Editing This File:")

    local current_filename = Utils.get_buffer_filename(0)
    if current_filename then
        table.insert(context_lines, current_filename)
        table.insert(context_lines, "")
    end
    table.insert(context_lines, "## User's Last Viewed Files:")

    local recent_files = Utils.get_last_opened_buffers(number_of_files_to_include)

    for _, file_info in ipairs(recent_files) do
        local filename = file_info.filename
        if filename and filename ~= current_filename then
            table.insert(context_lines, "### " .. filename)
            local content = Utils.get_text(vim.fn.bufnr(filename))
            table.insert(context_lines, "```")
            table.insert(context_lines, content)
            table.insert(context_lines, "```")
            table.insert(context_lines, "")
        end
    end

    return table.concat(context_lines, "\n")
end

return Utils
