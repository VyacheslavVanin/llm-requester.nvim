-- Chat session model.
--
-- A session stores only the conversation itself and some metadata. The system
-- prompt and editor context are request-scoped and are intentionally not
-- persisted: changing the configuration later still gives predictable
-- behaviour for existing chats.
--
-- Agent sessions additionally store assistant tool calls and tool results so
-- that a conversation can be resumed after restarting Neovim.

local Session = {}
Session.__index = Session

local function normalize_tool_calls(value)
    if type(value) ~= 'table' then
        return nil
    end

    local calls = {}
    for _, call in ipairs(value) do
        if type(call) == 'table' and type(call['function']) == 'table' then
            local fn = call['function']
            if type(fn.name) == 'string' and fn.name ~= '' then
                local id = type(call.id) == 'string' and call.id or ''
                if id == '' then
                    id = 'call_' .. tostring(#calls + 1)
                end
                table.insert(calls, {
                    id = id,
                    type = 'function',
                    ['function'] = {
                        name = fn.name,
                        arguments = type(fn.arguments) == 'string' and fn.arguments or '',
                    },
                })
            end
        end
    end

    return #calls > 0 and calls or nil
end

local function normalize_message(message)
    if type(message) ~= 'table' then
        return nil
    end
    if type(message.content) ~= 'string' then
        return nil
    end

    if message.role == 'user' then
        if message.content == '' then
            return nil
        end
        return { role = 'user', content = message.content }
    end

    if message.role == 'assistant' then
        local tool_calls = normalize_tool_calls(message.tool_calls)
        if message.content == '' and not tool_calls then
            return nil
        end

        local normalized = { role = 'assistant', content = message.content }
        if tool_calls then
            normalized.tool_calls = tool_calls
        end
        return normalized
    end

    if message.role == 'tool' then
        if type(message.tool_call_id) ~= 'string' or message.tool_call_id == '' then
            return nil
        end
        local normalized = {
            role = 'tool',
            tool_call_id = message.tool_call_id,
            content = message.content,
        }
        if type(message.name) == 'string' and message.name ~= '' then
            normalized.name = message.name
        end
        return normalized
    end

    return nil
end

function Session.new(options)
    options = options or {}

    local messages = {}
    for _, message in ipairs(options.messages or {}) do
        local normalized = normalize_message(message)
        if normalized then
            table.insert(messages, normalized)
        end
    end

    local cwd = options.cwd or vim.fn.getcwd()

    return setmetatable({
        version = 2,
        id = options.id,
        created_at = options.created_at or os.time(),
        updated_at = options.updated_at or os.time(),
        cwd = cwd,
        root = type(options.root) == 'string' and options.root or nil,
        mode = options.mode == 'agent' and 'agent' or 'chat',
        model = options.model or '',
        usage = type(options.usage) == 'table' and options.usage or nil,
        messages = messages,
    }, Session)
end

function Session.from_table(value)
    if type(value) ~= 'table' or type(value.id) ~= 'string' or value.id == '' then
        return nil
    end
    if type(value.messages) ~= 'table' then
        return nil
    end

    return Session.new({
        id = value.id,
        created_at = tonumber(value.created_at),
        updated_at = tonumber(value.updated_at),
        cwd = type(value.cwd) == 'string' and value.cwd or nil,
        root = type(value.root) == 'string' and value.root or nil,
        mode = value.mode,
        model = type(value.model) == 'string' and value.model or '',
        usage = type(value.usage) == 'table' and value.usage or nil,
        messages = value.messages,
    })
end

function Session:to_table()
    return {
        version = self.version,
        id = self.id,
        created_at = self.created_at,
        updated_at = self.updated_at,
        cwd = self.cwd,
        root = self.root,
        mode = self.mode,
        model = self.model,
        usage = self.usage,
        messages = self.messages,
    }
end

function Session:touch()
    self.updated_at = os.time()
end

function Session:is_empty()
    return #self.messages == 0
end

function Session:add_user(content)
    if type(content) ~= 'string' or content == '' then
        return
    end
    table.insert(self.messages, { role = 'user', content = content })
    self:touch()
end

---Adds an assistant message. Empty content is kept only when tool calls exist.
function Session:add_assistant(content, tool_calls)
    local text = type(content) == 'string' and content or ''
    local calls = normalize_tool_calls(tool_calls)

    if text == '' and not calls then
        return
    end

    local message = { role = 'assistant', content = text }
    if calls then
        message.tool_calls = calls
    end

    table.insert(self.messages, message)
    self:touch()
end

---Adds a tool result tied to an assistant tool call.
function Session:add_tool_result(tool_call_id, content, name)
    if type(tool_call_id) ~= 'string' or tool_call_id == '' then
        return
    end
    if type(content) ~= 'string' then
        return
    end

    local message = {
        role = 'tool',
        tool_call_id = tool_call_id,
        content = content,
    }
    if type(name) == 'string' and name ~= '' then
        message.name = name
    end

    table.insert(self.messages, message)
    self:touch()
end

function Session:add_usage(usage)
    if type(usage) ~= 'table' then
        return
    end

    local total = self.usage or { total_tokens = 0, input = 0, output = 0 }
    total.total_tokens = (tonumber(total.total_tokens) or 0) + (tonumber(usage.total_tokens) or 0)
    total.input = (tonumber(total.input) or 0) + (tonumber(usage.input) or 0)
    total.output = (tonumber(total.output) or 0) + (tonumber(usage.output) or 0)
    self.usage = total
end

-- Removes the last user message. Used when a request is stopped before an
-- assistant reply was produced, so the user can resend the prompt without
-- duplicating history. Returns the removed text, or nil when there is nothing
-- to remove.
function Session:remove_last_user(expected_content)
    local last = self.messages[#self.messages]
    if not last or last.role ~= 'user' then
        return nil
    end

    if expected_content ~= nil and last.content ~= expected_content then
        return nil
    end

    table.remove(self.messages)
    self:touch()
    return last.content
end

-- Rolls back an in-flight exchange: removes the last user message together
-- with any assistant tool calls and tool results that followed it.
function Session:rollback_pending_request()
    for index = #self.messages, 1, -1 do
        if self.messages[index].role == 'user' then
            local content = self.messages[index].content
            for remove_index = #self.messages, index, -1 do
                table.remove(self.messages, remove_index)
            end
            self:touch()
            return content
        end
    end
    return nil
end

-- Builds the message list sent to the LLM. The system prompt and the current
-- editor context are request-scoped; the persisted history never contains them.
function Session:build_messages(system_prompt, context)
    local messages = {}

    if type(system_prompt) == 'string' and system_prompt ~= '' then
        table.insert(messages, { role = 'system', content = system_prompt })
    end

    if type(context) == 'string' and context ~= '' then
        table.insert(messages, { role = 'system', content = 'additional_context:\n' .. context })
    end

    for _, message in ipairs(self.messages) do
        local copy = { role = message.role, content = message.content }
        if message.tool_calls then
            copy.tool_calls = message.tool_calls
        end
        if message.tool_call_id then
            copy.tool_call_id = message.tool_call_id
        end
        if message.name then
            copy.name = message.name
        end
        table.insert(messages, copy)
    end

    return messages
end

return Session
