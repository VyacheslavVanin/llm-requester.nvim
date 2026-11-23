-- Chat session model.
--
-- A session stores only the conversation itself (user/assistant messages) and
-- some metadata. The system prompt and editor context are request-scoped and
-- are intentionally not persisted: changing the configuration later still
-- gives predictable behaviour for existing chats.

local Session = {}
Session.__index = Session

local function normalize_message(message)
    if type(message) ~= 'table' then
        return nil
    end
    if message.role ~= 'user' and message.role ~= 'assistant' then
        return nil
    end
    if type(message.content) ~= 'string' then
        return nil
    end
    return { role = message.role, content = message.content }
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

    return setmetatable({
        version = 1,
        id = options.id,
        created_at = options.created_at or os.time(),
        updated_at = options.updated_at or os.time(),
        cwd = options.cwd or vim.fn.getcwd(),
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
        model = type(value.model) == 'string' and value.model or '',
        usage = type(value.usage) == 'table' and value.usage or nil,
        messages = value.messages,
    })
end

function Session:to_table()
    return {
        version = 1,
        id = self.id,
        created_at = self.created_at,
        updated_at = self.updated_at,
        cwd = self.cwd,
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

function Session:add_assistant(content)
    if type(content) ~= 'string' or content == '' then
        return
    end
    table.insert(self.messages, { role = 'assistant', content = content })
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
        table.insert(messages, { role = message.role, content = message.content })
    end

    return messages
end

return Session
