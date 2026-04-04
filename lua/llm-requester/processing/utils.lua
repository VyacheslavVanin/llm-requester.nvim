local ProcessingUtils = {}
local utils = require("llm-requester.utils")

-- Helper function to get API key from file
local function get_api_key(config)
    if config.api_key_file ~= '' then
        return utils.read_api_key_from_file(config.api_key_file)
    else
        return ''
    end
end

local function apply_tool_use(result_text, ctx)
    local tool_use_pattern = "BEGIN_TOOL_USE%s*(.-)%s*END_TOOL_USE"
    local tool_use_match = string.match(result_text, tool_use_pattern)

    if not tool_use_match then
        return result_text
    end

    vim.notify("LLM tool use detected!")
    local ok, tool_json = pcall(vim.json.decode, tool_use_match)
    if not ok or tool_json.tool_name ~= "apply_function" then
        return result_text
    end

    local source = tool_json.arguments.source
    vim.notify("Applying function: " .. source)

    -- Extract the selected text from ctx
    local selected_text_pattern = "BEGIN_SELECTED_TEXT%s*(.-)%s*END_SELECTED_TEXT"
    local selected_text = string.match(ctx, selected_text_pattern) or ""

    -- Execute the Lua function
    local func, err = load(source)
    if not func then
        return "Error loading Lua code: " .. tostring(err)
    end

    local ok_exec, result_val = pcall(func)
    if not ok_exec then
        return "Error executing Lua code: " .. tostring(result_val)
    end

    if type(result_val) == "function" then
        local ok_call, final_result = pcall(result_val, selected_text)
        if ok_call then
            return tostring(final_result)
        else
            return "Error calling Lua function: " .. tostring(final_result)
        end
    else
        return tostring(result_val)
    end
end

local function get_text_inside_tags(xml_string, tag_name)
    -- Construct the regex pattern to match text inside specific tags
    local pattern = string.format("<%s>(.-)</%s>", tag_name, tag_name)
    -- Use gmatch to find all matches
    for _ in string.gmatch(xml_string, pattern) do
        return _  -- Return the first match found
    end
    return nil  -- Return nil if no match is found
end


function ProcessingUtils.handle_openai_request(system_message, ctx, extended_ctx, result_buf, result_win, config, on_close_fn)
    local messages = {
        {
            role = "system",
            content = system_message,
        },
    }
    if extended_ctx then
        table.insert(messages, {
            role = "user",
            content = extended_ctx
        })
    end
    table.insert(messages, {
        role = "user",
        content = ctx
    })

    local json_data = vim.json.encode(vim.tbl_extend('force', {
        model = config.openai_model,
        messages = messages,
        stream = false,
        temperature = 0.2,
        max_tokens = config.context_size
    }, config.additional_params or {}))

    local headers = {
        'Authorization: Bearer ' .. get_api_key(config),
        'Content-Type: application/json'
    }
    -- store json_data to temporal file in /tmp/
    local temp_file = '/tmp/llm-processing-data.json'
    vim.fn.writefile({json_data}, temp_file)

    vim.fn.jobstart({'curl', '-s', '-X', 'POST', config.openai_url .. '/chat/completions', '-H', headers[1], '-H', headers[2], '--data-binary', '@' .. temp_file}, {
        on_stdout = function(_, data)
            local response = table.concat(data, '')
            if #response > 0 then
                -- store response to /tmp/llm-requester-processing-response.log
                vim.fn.writefile({response}, '/tmp/llm-requester-processing-response.log')
            end

            local ok, result = pcall(vim.json.decode, response)
            result = result.response or result
            if ok and result.choices and result.choices[1] and result.choices[1].message then
                local result_text = result.choices[1].message.content
                
                result_text = apply_tool_use(result_text, ctx)

                vim.schedule(function()
                    if vim.api.nvim_win_is_valid(result_win) then
                        -- Split the result into lines (don't expect specific tags for processing)
                        local result_lines = {}
                        for line in vim.gsplit(result_text, '\n') do
                            table.insert(result_lines, line)
                        end

                        vim.api.nvim_buf_set_option(result_buf, 'modifiable', true)
                        vim.api.nvim_buf_set_lines(result_buf, 0, -1, false, result_lines)

                        -- Adjust window height based on content
                        vim.api.nvim_win_set_height(result_win, math.min(#result_lines, config.menu_height))

                        vim.api.nvim_buf_set_option(result_buf, 'modifiable', false)
                    end
                end)
            end
        end,
        on_exit = function(_, code)
            if code ~= 0 then
                vim.schedule(function()
                    if vim.api.nvim_win_is_valid(result_win) then
                        vim.api.nvim_buf_set_option(result_buf, 'modifiable', true)
                        vim.api.nvim_buf_set_lines(result_buf, 0, -1, false, {'Error processing text'})
                        vim.api.nvim_buf_set_option(result_buf, 'modifiable', false)
                    end
                end)
            end
        end
    })
end

return ProcessingUtils
