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
    local text = Tools.get_text(0)
    Tools.make_user_request(text)
end


function Tools.setup(config)
vim.keymap.set('n', '<leader>t', test_action, { desc = 'Test action' })
Tools.send_start_session()
end

function Tools.make_user_request(message)
    local json_data = vim.json.encode({
        input = message,
    })

    local handle = function(_, data)
        local response = table.concat(data, '')
        local success, decoded = pcall(vim.json.decode, response)
        if success then
            Tools.show_in_buf_mutable(0, vim.split(decoded.message, '\n'))
            if decoded.requires_approval then
                Tools.process_required_approval(decoded)
            end
        end
    end
    local handle_on_exit = function(_, exit_code)
    end
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

function Tools.process_required_approval(decoded)
    local message = decoded.message
    local request_id = decoded.request_id
    local tool = decoded.tool
    local popup_content = "LLM wants to use tool:\n - " .. tool .. "\n" ..
                          "approve (y/n)?"
    local function on_approve()
        Tools.send_approve(request_id, true)
    end
    local function on_deny()
        Tools.send_approve(request_id, false)
    end
    Tools.show_choose_window(
        popup_content,
        {
            y = on_approve,
            n = on_deny,
        }
    )
end

function Tools.send_approve(request_id, approve)
    local json_data = vim.json.encode({
        request_id = request_id,
        approve = approve,
    })
    local handle = function(_, data)
        local response = table.concat(data, '')
        local success, decoded = pcall(vim.json.decode, response)
        if success then
            Tools.show_in_buf_mutable(0, vim.split(decoded.message, '\n'))
            vim.print(decoded.requires_approval)
            if decoded.requires_approval then
                Tools.process_required_approval(decoded)
            end
        end
    end
    local handle_on_exit = function(_, exit_code)
    end
    fn.jobstart({'curl', '-s',
                 '-X', 'POST',
                 '-H', 'Content-Type: application/json',
                 'http://localhost:8000/approve',
                 '-d', json_data}, {
        on_stdout = handle,
        on_exit = handle_on_exit,
        stdout_buffered = true,
    })
end

function Tools.send_start_session()
    local json_data = vim.json.encode({
        current_directory = vim.fn.getcwd(),
    })
    local handle = function(_, data)
    end
    local handle_on_exit = function(_, exit_code)
    end
    fn.jobstart({'curl', '-s',
                 '-X', 'POST',
                 '-H', 'Content-Type: application/json',
                 'http://localhost:8000/start_session',
                 '-d', json_data}, {
        on_stdout = handle,
        on_exit = handle_on_exit,
        stdout_buffered = true,
    })
end

return Tools

