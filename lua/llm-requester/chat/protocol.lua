-- OpenAI-compatible payload and response helpers.
--
-- Kept separate from the curl transport so that tool-call parsing can be
-- tested without spawning a process.

local Protocol = {}

local function normalize_arguments(value)
    if type(value) == 'string' then
        return value
    end
    if type(value) == 'table' then
        local ok, encoded = pcall(vim.json.encode, value)
        return ok and encoded or ''
    end
    return ''
end

local function normalize_tool_call(value, fallback_id)
    if type(value) ~= 'table' or type(value['function']) ~= 'table' then
        return nil
    end

    local fn = value['function']
    if type(fn.name) ~= 'string' or fn.name == '' then
        return nil
    end

    local id = type(value.id) == 'string' and value.id or ''
    if id == '' then
        id = fallback_id or ''
    end

    return {
        id = id,
        type = 'function',
        ['function'] = {
            name = fn.name,
            arguments = normalize_arguments(fn.arguments),
        },
    }
end

local ToolCallBuffer = {}
ToolCallBuffer.__index = ToolCallBuffer

---Creates a buffer that reassembles streamed tool-call fragments.
function Protocol.new_tool_call_buffer()
    return setmetatable({
        by_index = {},
        last_index = -1,
        counter = 0,
    }, ToolCallBuffer)
end

function ToolCallBuffer:_slot(index)
    local slot = self.by_index[index]
    if not slot then
        slot = {
            id = '',
            type = 'function',
            ['function'] = { name = '', arguments = '' },
        }
        self.by_index[index] = slot
    end
    return slot
end

function ToolCallBuffer:push(fragments)
    if type(fragments) ~= 'table' then
        return
    end

    for position, fragment in ipairs(fragments) do
        if type(fragment) == 'table' then
            local index = tonumber(fragment.index)
            if index == nil then
                index = math.max(0, position - 1)
            end
            self.last_index = math.max(self.last_index, index)

            local slot = self:_slot(index)
            if type(fragment.id) == 'string' and fragment.id ~= '' then
                slot.id = fragment.id
            end
            if type(fragment.type) == 'string' and fragment.type ~= '' then
                slot.type = fragment.type
            end

            local fn = fragment['function']
            if type(fn) == 'table' then
                if type(fn.name) == 'string' and fn.name ~= '' then
                    if slot['function'].name == '' then
                        slot['function'].name = fn.name
                    elseif slot['function'].name ~= fn.name
                        and not vim.endswith(slot['function'].name, fn.name) then
                        slot['function'].name = slot['function'].name .. fn.name
                    end
                end
                if type(fn.arguments) == 'string' then
                    slot['function'].arguments = slot['function'].arguments .. fn.arguments
                end
            end
        end
    end
end

---Returns a dense, index-ordered list of assembled tool calls.
function ToolCallBuffer:list()
    local calls = {}

    for index = 0, self.last_index do
        local slot = self.by_index[index]
        if slot and slot['function'].name ~= '' then
            self.counter = self.counter + 1
            if slot.id == '' then
                slot.id = 'call_' .. tostring(self.counter)
            end
            table.insert(calls, slot)
        end
    end

    return calls
end

---Builds the JSON request body.
function Protocol.build_payload(options, config)
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

    if type(options.tools) == 'table' and #options.tools > 0 then
        payload.tools = options.tools
        if options.tool_choice ~= nil then
            payload.tool_choice = options.tool_choice
        end
        if options.parallel_tool_calls ~= nil then
            payload.parallel_tool_calls = options.parallel_tool_calls
        end
    end

    return vim.tbl_deep_extend('force', payload, config.additional_params or {})
end

function Protocol.extract_error(value)
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

function Protocol.extract_usage(value)
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

---Extracts the assistant text from a non-streamed completion.
function Protocol.extract_content(value)
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

---Extracts tool calls from a non-streamed completion.
function Protocol.extract_tool_calls(value)
    if type(value) ~= 'table' or type(value.choices) ~= 'table' then
        return {}
    end

    local choice = value.choices[1]
    local message = type(choice) == 'table' and choice.message or nil
    local calls = type(message) == 'table' and message.tool_calls or nil
    if type(calls) ~= 'table' then
        return {}
    end

    local result = {}
    for index, call in ipairs(calls) do
        local normalized = normalize_tool_call(call, 'call_' .. tostring(index))
        if normalized then
            table.insert(result, normalized)
        end
    end

    return result
end

function Protocol.finish_reason(value)
    if type(value) ~= 'table' or type(value.choices) ~= 'table' then
        return nil
    end
    local choice = value.choices[1]
    return type(choice) == 'table' and choice.finish_reason or nil
end

return Protocol
