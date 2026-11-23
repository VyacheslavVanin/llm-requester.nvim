local Sse = require('llm-requester.chat.sse')

local Test = _G.Test

local function event(content)
    return vim.json.encode({
        choices = { { delta = { content = content } } },
    })
end

do
    local events = {}
    local parser = Sse.new({
        on_event = function(value)
            table.insert(events, value)
        end,
    })

    local first = event('Hello')
    parser:feed('data: ' .. first:sub(1, 7))
    parser:feed(first:sub(8) .. '\n\n')
    parser:feed('data: ' .. event(' world') .. '\n\n')

    Test.eq(#events, 2, 'two events are parsed from split chunks')
    Test.eq(events[1].choices[1].delta.content, 'Hello', 'first event content')
    Test.eq(events[2].choices[1].delta.content, ' world', 'second event content')
end

do
    local events = {}
    local parser = Sse.new({
        on_event = function(value)
            table.insert(events, value)
        end,
    })

    parser:feed('data: ' .. event('crlf') .. '\r\n\r\n')
    Test.eq(#events, 1, 'CRLF line endings are supported')
    Test.eq(events[1].choices[1].delta.content, 'crlf', 'CRLF event content')
end

do
    local parser = Sse.new({})
    parser:feed('data: [DONE]\n\n')
    Test.truthy(parser.done, '[DONE] marks the stream as finished')
end

do
    local events = {}
    local raw = {}
    local parser = Sse.new({
        on_event = function(value)
            table.insert(events, value)
        end,
        on_raw = function(line)
            table.insert(raw, line)
        end,
    })

    parser:feed('data: {not valid json}\n\n')
    parser:feed('{"error":"provider exploded"}\n')

    Test.eq(#events, 0, 'invalid JSON does not produce events')
    Test.eq(#raw, 1, 'non-SSE lines are reported as raw data')
    Test.eq(raw[1], '{"error":"provider exploded"}', 'raw line content')
end

do
    local events = {}
    local parser = Sse.new({
        on_event = function(value)
            table.insert(events, value)
        end,
    })

    parser:feed('data: ' .. event('partial'))
    Test.eq(#events, 0, 'unterminated line is buffered')
    parser:finish()
    Test.eq(#events, 1, 'finish flushes the last buffered line')
    Test.eq(events[1].choices[1].delta.content, 'partial', 'flushed event content')
end
