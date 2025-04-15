local Tools = {}

local api = vim.api
local fn = vim.fn


local utils = require("llm-requester.utils")

Tools.default_config = {
    split_ratio = 0.6,
    prompt_split_ratio = 0.2, -- parameter to control dimensions of prompt and response windows
    open_prompt_window_key = '<leader>ai',
    request_keys = '<leader>r',
    close_keys = '<leader>q',
    history_keys = '<leader>h',
    clear_keys = '<leader>cc',
    --stream = false,
}

local config = vim.deepcopy(Tools.default_config)

local function test_action()
    local text = utils.get_text(0)
    Tools.make_user_request(text)
end


function Tools.setup(config)
vim.keymap.set('n', '<leader>t', Tools.open_agent_window, { desc = 'Test action' })
Tools.send_start_session()
end


local prompt_win, prompt_buf, response_win, response_buf

function Tools.open_agent_window()
    local split_ratio = 0.5
    local prompt_split_ratio = 0.2
    prompt_win, prompt_buf, response_win, response_buf =
        utils.create_chat_split(config.split_ratio, config.prompt_split_ratio)

    -- Set keymaps
    local close_func = function() 
        if api.nvim_win_is_valid(prompt_win) then api.nvim_win_close(prompt_win, true) end
        if api.nvim_win_is_valid(response_win) then api.nvim_win_close(response_win, true) end
    end

    vim.keymap.set('v', config.close_keys, close_func, { desc = 'Close LLMRequester window' })
    vim.keymap.set('n', config.close_keys, close_func, { desc = 'Close LLMRequester window' })
    api.nvim_buf_set_keymap(prompt_buf, 'i', '<M-CR>', '', { callback = Tools.send_request })
    api.nvim_buf_set_keymap(prompt_buf, 'n', config.request_keys, '', { callback = Tools.send_request })
    api.nvim_buf_set_keymap(prompt_buf, 'n', config.close_keys, '', { callback = close_func })
    api.nvim_buf_set_keymap(prompt_buf, 'n', config.history_keys, '', { callback = Tools.show_history })
    api.nvim_buf_set_keymap(prompt_buf, 'n', config.clear_keys, '', { callback = Tools.clear_chat })
    api.nvim_buf_set_keymap(response_buf, 'n', config.close_keys, '', { callback = close_func })
    api.nvim_buf_set_keymap(response_buf, 'n', config.history_keys, '', { callback = Tools.show_history })
    api.nvim_buf_set_keymap(response_buf, 'n', config.clear_keys, '', { callback = Tools.clear_chat })
end

function Tools.send_request()
    local text = utils.get_text(prompt_buf)
    Tools.make_user_request(text)
end

function Tools.show_history()
end

function Tools.clear_chat()
    Tools.send_start_session()
    utils.show_in_buf(response_buf, {})
end

function Tools.make_user_request(message)
    local json_data = vim.json.encode({
        input = message,
    })

    local handle = function(_, data)
        local response = table.concat(data, '')
        local success, decoded = pcall(vim.json.decode, response)
        if success then
            utils.show_in_buf(response_buf, vim.split(decoded.message, '\n'))
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
            utils.show_in_buf(response_buf, vim.split(decoded.message, '\n'))
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

