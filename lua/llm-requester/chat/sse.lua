-- Parses a stream of Server-Sent Events (SSE) chunks.
--
-- The parser is intentionally transport agnostic: feed() accepts arbitrary
-- strings, which may contain zero, one or many lines. Lines are buffered
-- until a newline is received, so chunks split in the middle of a JSON
-- payload are handled correctly.

local Sse = {}
Sse.__index = Sse

local function is_sse_field(line)
    return line:match('^event:') ~= nil
        or line:match('^id:') ~= nil
        or line:match('^retry:') ~= nil
end

function Sse.new(handlers)
    return setmetatable({
        handlers = handlers or {},
        buffer = '',
        done = false,
    }, Sse)
end

function Sse:_handle_line(raw_line)
    local line = raw_line:gsub('\r$', '')

    if line == '' or line:sub(1, 1) == ':' then
        return
    end

    local payload = line:match('^data:%s?(.*)$')
    if not payload then
        if not is_sse_field(line) and self.handlers.on_raw then
            self.handlers.on_raw(line)
        end
        return
    end

    payload = payload:gsub('%s+$', '')

    if payload == '[DONE]' then
        self.done = true
        return
    end

    local ok, decoded = pcall(vim.json.decode, payload)
    if ok and decoded ~= nil and self.handlers.on_event then
        self.handlers.on_event(decoded)
    end
end

function Sse:feed(chunk)
    if not chunk or chunk == '' then
        return
    end

    self.buffer = self.buffer .. chunk

    while true do
        local newline = self.buffer:find('\n', 1, true)
        if not newline then
            break
        end

        local line = self.buffer:sub(1, newline - 1)
        self.buffer = self.buffer:sub(newline + 1)
        self:_handle_line(line)
    end
end

function Sse:finish()
    if self.buffer ~= '' then
        self:_handle_line(self.buffer)
        self.buffer = ''
    end
end

return Sse
