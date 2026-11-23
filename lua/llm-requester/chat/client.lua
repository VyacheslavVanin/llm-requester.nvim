-- OpenAI-compatible chat client built on top of the curl executable.
--
-- The transport is intentionally isolated here: callbacks are always invoked
-- outside of libuv's fast context, and streaming chunks are coalesced before
-- reaching the UI.

local Sse = require('llm-requester.chat.sse')
local utils = require('llm-requester.utils')

local Client = {}

local MAX_ERROR_LENGTH = 800

local function truncate(text)
    local value = tostring(text or ''):gsub('%s+$', '')
    if value == '' then
        return 'unknown error'
    end
    if #value > MAX_ERROR_LENGTH then
        return value:sub(1, MAX_ERROR_LENGTH) .. '...'
    end
    return value
end

local function extract_error(value)
    if type(value) ~= 'table' then
        return nil
    end

    local error_value = value.error
    if error_value ~= nil and error_value ~= vim.NIL then
        if type(error_value) == 'table' then
            if type(error_value.message) == 'string' then
                return error_value.message
            end
            return vim.inspect(error_value)
        end
        return tostring(error_value)
    end

    if type(value.message) == 'string' and value.choices == nil then
        return value.message
    end

    return nil
end

local function extract_usage(value)
    if type(value) ~= 'table' or type(value.usage) ~= 'table' then
        return nil
    end

    local usage = value.usage
    local input = tonumber(usage.prompt_tokens) or tonumber(usage.input) or 0
    local output = tonumber(usage.completion_tokens) or tonumber(usage.output) or 0
    local total = tonumber(usage.total_tokens) or (input + output)

    return {
        total_tokens = total,
        input = input,
        output = output,
    }
end

local function get_api_key(config)
    if type(config.api_key_file) == 'string' and config.api_key_file ~= '' then
        local key = utils.read_api_key_from_file(config.api_key_file)
        if key and key ~= '' then
            return key
        end
    end

    if type(config.api_key) == 'string' and config.api_key ~= '' then
        return config.api_key
    end

    return os.getenv('LLM_API_KEY')
end

local function build_payload(options, config)
    local payload = {
        model = config.openai_model,
        messages = options.messages,
        stream = config.stream and true or false,
    }

    if config.temperature ~= nil then
        payload.temperature = config.temperature
    end

    if config.top_p ~= nil then
        payload.top_p = config.top_p
    end

    if config.stream then
        payload.stream_options = { include_usage = true }
    end

    return vim.tbl_deep_extend('force', payload, config.additional_params or {})
end

local function append_seconds_option(command, flag, value)
    local seconds = tonumber(value)
    if seconds and seconds > 0 then
        table.insert(command, flag)
        table.insert(command, tostring(seconds))
    end
end

local function build_command(config, endpoint)
    local command = {
        'curl', '-sS',
        '-X', 'POST', endpoint,
        '-H', 'Content-Type: application/json',
    }

    if config.stream then
        table.insert(command, '-N')
    end

    local api_key = get_api_key(config)
    if api_key and api_key ~= '' then
        table.insert(command, '-H')
        table.insert(command, 'Authorization: Bearer ' .. api_key)
    end

    if config.no_verify_ssl then
        table.insert(command, '--insecure')
    end

    append_seconds_option(command, '--connect-timeout', config.connect_timeout)
    append_seconds_option(command, '--max-time', config.timeout)

    local stall_timeout = tonumber(config.stall_timeout)
    if stall_timeout and stall_timeout > 0 then
        table.insert(command, '--speed-limit')
        table.insert(command, '1')
        table.insert(command, '--speed-time')
        table.insert(command, tostring(stall_timeout))
    end

    table.insert(command, '--data-binary')
    table.insert(command, '@-')

    return command
end

-- Coalesces many small SSE deltas into a single scheduled UI update.
local function make_delta_emitter(callback)
    local pending = ''
    local scheduled = false

    local function flush()
        scheduled = false
        if pending == '' then
            return
        end

        local chunk = pending
        pending = ''
        if callback then
            callback(chunk)
        end
    end

    return {
        push = function(text)
            if not text or text == '' then
                return
            end

            pending = pending .. text
            if not scheduled then
                scheduled = true
                vim.schedule(flush)
            end
        end,
        flush = flush,
    }
end

local function emit_error(options, message, partial)
    if options.on_error then
        options.on_error(truncate(message), partial or '')
    end
end

local function handle_stream_exit(options, obj, state)
    state.delta.flush()

    if state.error then
        emit_error(options, state.error, state.text)
        return
    end

    if (obj.code or 0) ~= 0 then
        emit_error(options, obj.stderr or ('curl exited with code ' .. tostring(obj.code)), state.text)
        return
    end

    if state.text == '' then
        local raw = table.concat(state.raw_lines, '\n'):gsub('%s+$', '')
        if raw ~= '' then
            local decoded_ok, decoded = pcall(vim.json.decode, raw)
            local message = decoded_ok and (extract_error(decoded) or 'unexpected non-SSE response') or raw
            emit_error(options, message, '')
            return
        end
    end

    if state.usage and options.on_usage then
        options.on_usage(state.usage)
    end

    if options.on_finish then
        options.on_finish(state.text)
    end
end

local function start_stream(options, command, body)
    local state = {
        text = '',
        usage = nil,
        error = nil,
        raw_lines = {},
        delta = make_delta_emitter(options.on_delta),
    }

    local sse = Sse.new({
        on_event = function(event)
            local event_error = extract_error(event)
            if event_error then
                state.error = event_error
                return
            end

            local choices = event.choices
            if type(choices) ~= 'table' or not choices[1] then
                local event_usage = extract_usage(event)
                if event_usage then
                    state.usage = event_usage
                end
                return
            end

            local choice = choices[1]
            local delta = choice.delta
            if type(delta) ~= 'table' then
                delta = choice.message
            end

            local content = type(delta) == 'table' and delta.content or nil
            if type(content) ~= 'string' then
                content = choice.text
            end

            if type(content) == 'string' and content ~= '' then
                state.text = state.text .. content
                state.delta.push(content)
            end

            local event_usage = extract_usage(event)
            if event_usage then
                state.usage = event_usage
            end
        end,
        on_raw = function(line)
            table.insert(state.raw_lines, line)
        end,
    })

    local started, process = pcall(vim.system, command, {
        stdin = body,
        text = true,
        stderr = true,
        stdout = function(_, data)
            if data and data ~= '' then
                sse:feed(data)
            end
        end,
    }, function(obj)
        vim.schedule(function()
            sse:finish()
            handle_stream_exit(options, obj, state)
        end)
    end)

    if not started then
        emit_error(options, process, '')
        return nil
    end

    return process
end

local function extract_content(value)
    if type(value) ~= 'table' or type(value.choices) ~= 'table' then
        return nil
    end

    local choice = value.choices[1]
    if type(choice) ~= 'table' then
        return nil
    end

    local message = choice.message
    local content = type(message) == 'table' and message.content or nil
    if type(content) ~= 'string' then
        content = choice.text
    end

    if type(content) ~= 'string' then
        return nil
    end

    return content
end

local function start_non_stream(options, command, body)
    local started, process = pcall(vim.system, command, {
        stdin = body,
        text = true,
        stderr = true,
        stdout = true,
    }, function(obj)
        vim.schedule(function()
            if (obj.code or 0) ~= 0 then
                emit_error(options, obj.stderr or ('curl exited with code ' .. tostring(obj.code)), '')
                return
            end

            local response_body = obj.stdout or ''
            if response_body == '' then
                emit_error(options, 'empty response from the LLM provider', '')
                return
            end

            local decoded_ok, decoded = pcall(vim.json.decode, response_body)
            if not decoded_ok then
                emit_error(options, 'invalid JSON response: ' .. response_body, '')
                return
            end

            -- Some OpenAI-compatible providers wrap the payload in "response".
            local data = decoded
            if type(decoded) == 'table' and type(decoded.response) == 'table' then
                data = decoded.response
            end

            local response_error = extract_error(data)
            if response_error then
                emit_error(options, response_error, '')
                return
            end

            local content = extract_content(data)
            if content == nil then
                emit_error(options, 'unexpected response format: ' .. response_body, '')
                return
            end

            local usage = extract_usage(data)
            if usage and options.on_usage then
                options.on_usage(usage)
            end

            if options.on_finish then
                options.on_finish(content)
            end
        end)
    end)

    if not started then
        emit_error(options, process, '')
        return nil
    end

    return process
end

---@param options table
---@param options.config table
---@param options.messages table
---@param options.on_delta fun(text: string)|nil
---@param options.on_usage fun(usage: table)|nil
---@param options.on_finish fun(content: string)|nil
---@param options.on_error fun(message: string, partial: string)|nil
---@return table|nil process vim.system handle, useful for cancellation
function Client.request(options)
    local config = options.config
    if type(config) ~= 'table' then
        emit_error(options, 'chat config is missing', '')
        return nil
    end

    local endpoint = utils.completions_url(config.openai_url)
    if endpoint == '' then
        emit_error(options, 'openai_url is not configured', '')
        return nil
    end

    local payload = build_payload(options, config)
    local encoded_ok, body = pcall(vim.json.encode, payload)
    if not encoded_ok then
        emit_error(options, 'failed to encode request: ' .. tostring(body), '')
        return nil
    end

    local command = build_command(config, endpoint)
    if config.stream then
        return start_stream(options, command, body)
    end

    return start_non_stream(options, command, body)
end

return Client
