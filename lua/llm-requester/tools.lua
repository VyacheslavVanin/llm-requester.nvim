local Tools = {}

local api = vim.api
local fn = vim.fn


-- Get whole buffers text as string. buf = 0 for current buffer
function Tools.get_text(buf)
    return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
end

-- Show content in current buffer exclusivly
function Tools.show_in_buf(buf, content)
    api.nvim_buf_set_option(buf, 'modifiable', true)
    api.nvim_buf_set_lines(buf, 0, -1, false, content)
    api.nvim_buf_set_option(buf, 'modifiable', false)
end

-- Append lines to current buffer
function Tools.append_to_buf(buf, content)
    api.nvim_buf_set_option(buf, 'modifiable', true)
    api.nvim_buf_set_lines(buf, -1, -1, false, content)
    api.nvim_buf_set_option(buf, 'modifiable', false)
end

-- Show content in current buffer exclusivly
function Tools.show_in_buf_mutable(buf, content)
    api.nvim_buf_set_lines(buf, 0, -1, false, content)
end

-- Append lines to current buffer
function Tools.append_to_buf_mutable(buf, content)
    api.nvim_buf_set_lines(buf, -1, -1, false, content)
end

-- Append string to last string if buffer bufnr
function Tools.append_to_last_line(bufnr, text)
    local last_line = vim.api.nvim_buf_line_count(bufnr) - 1  -- lines are 0-indexed
    local current_content = vim.api.nvim_buf_get_lines(bufnr, last_line, last_line + 1, false)[1] or ""
    local inserted_text = vim.split(text, '\n', {})
    inserted_text[1] = current_content .. inserted_text[1]
    vim.api.nvim_buf_set_lines(bufnr, last_line, last_line + 1, false, inserted_text)
end

function Tools.show_choose_window(text, map)
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
    Tools.show_in_buf(bufnr, content)

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


local function test_action()
    local function on_approve()
        vim.print("Approved!")
    end
    local function on_deny()
        vim.print("Denied!")
    end
    Tools.show_choose_window(
        'Approve request ' .. 'request_id' .. '?\n' ..
        '\'y\' - yes\n\'n\' - no',
        {
            y = on_approve,
            n = on_deny,
        }
    )
end


function Tools.setup(config)
vim.keymap.set('n', '<leader>t', test_action, { desc = 'Test action' })
end

function Tools.make_user_request(message)
    local json_data = vim.json.encode({
        input = message,
    })

    local handle = function(_, data)
        local response = table.concat(data, '')
        local success, decoded = pcall(vim.json.decode, response)
        vim.print(success, data, decoded)
        if success then
            Tools.show_in_buf_mutable(0, vim.split(decoded.message, '\n'))
        end
    end
    local handle_on_exit = function(_, exit_code)
    end
    local content_type = ''
    fn.jobstart({'curl', '-s',
                 '-X', 'POST',
                 '-H', 'Content-Type: application/json',
                 'http://localhost:8000/user_request',
                 '-d', json_data}, {
        on_stdout = handle,
        on_exit = handle_on_exit,
        stdout_buffered = true,
    })
end

return Tools

