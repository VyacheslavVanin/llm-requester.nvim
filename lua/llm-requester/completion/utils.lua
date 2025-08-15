local api = vim.api
local fn = vim.fn

local Utils = {}


local function get_text_inside_tags(xml_string, tag_name)
    -- Construct the regex pattern to match text inside specific tags
    local pattern = string.format("<%s>(.-)</%s>", tag_name, tag_name)
    -- Use gmatch to find all matches
    for _ in string.gmatch(xml_string, pattern) do
        return _  -- Return the first match found
    end
    return nil  -- Return nil if no match is found
end


function Utils.handle_openai_request(system_message, ctx, completion_buf, completion_win, config, on_close_fn)
    local json_data = vim.json.encode({
        model = config.openai_model,
        messages = {
            {
                role = "system",
                content = system_message
            },
            {
                role = "user",
                content = ctx
            }
        },
        stream = false,
        temperature = 0.2,
        max_tokens = config.context_size
    })

    local headers = {
        'Authorization: Bearer ' .. config.openai_api_key,
        'Content-Type: application/json'
    }

    fn.jobstart({'curl', '-s', '-X', 'POST', config.openai_url .. '/chat/completions', '-H', headers[1], '-H', headers[2], '-d', json_data}, {
        on_stdout = function(_, data)
            local response = table.concat(data, '')
            local ok, result = pcall(vim.json.decode, response)
            result = result.response or result
            if ok and result.choices and result.choices[1] and result.choices[1].message then
                local suggestions = {}
                local content = get_text_inside_tags(result.choices[1].message.content, 'completion')
                if content == nil then
                    on_close_fn()
                    return
                end
                for line in vim.gsplit(content, '\n') do
                    if line ~= '' then
                        table.insert(suggestions, line)
                    end
                end
                vim.schedule(function()
                    if vim.api.nvim_win_is_valid(completion_win) then
                        vim.api.nvim_buf_set_lines(completion_buf, 0, -1, false, suggestions)
                        vim.api.nvim_win_set_height(completion_win,
                            math.min(#suggestions, config.menu_height))
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


function Utils.handle_ollama_request(system_message, ctx, completion_buf, completion_win, config, on_close_fn)
    local json_data = vim.json.encode({
        model = config.ollama_model,
        messages = {
            {
                role = "system",
                content = system_message
            },
            {
                role = "user",
                content = ctx
            }
        },
        stream = false,
        options = {
            temperature = 0.2,
            num_ctx = config.context_size
        }
    })

    fn.jobstart({'curl', '-s', '-X', 'POST', config.ollama_url, '-d', json_data}, {
        on_stdout = function(_, data)
            local response = table.concat(data, '')
            local ok, result = pcall(vim.json.decode, response)
            if ok and result.message and result.message.content then
                local suggestions = {}
                local content = get_text_inside_tags(result.message.content, 'completion')
                if content == nil then
                    on_close_fn()
                    return
                end
                for line in vim.gsplit(content, '\n') do
                    if line ~= '' then
                        table.insert(suggestions, line)
                    end
                end
                vim.schedule(function()
                    if vim.api.nvim_win_is_valid(completion_win) then
                        vim.api.nvim_buf_set_lines(completion_buf, 0, -1, false, suggestions)
                        vim.api.nvim_win_set_height(completion_win,
                            math.min(#suggestions, config.menu_height))
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


return Utils

