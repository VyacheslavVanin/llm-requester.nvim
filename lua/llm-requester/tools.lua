local Tools = {}

local api = vim.api
local fn = vim.fn


local utils = require("llm-requester.utils")

local function test_action()
    local text = utils.get_text(0)
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
            utils.show_in_buf_mutable(0, vim.split(decoded.message, '\n'))
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
    utils.show_choose_window(
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
            utils.show_in_buf_mutable(0, vim.split(decoded.message, '\n'))
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

