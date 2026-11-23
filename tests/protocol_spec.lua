local Protocol = require('llm-requester.chat.protocol')

local Test = _G.Test

do
    local payload = Protocol.build_payload({
        messages = { { role = 'user', content = 'hi' } },
        tools = { { type = 'function', ['function'] = { name = 'read_file' } } },
        tool_choice = 'auto',
        parallel_tool_calls = false,
    }, {
        openai_model = 'model',
        stream = false,
        temperature = 0.1,
        additional_params = { extra = true },
    })

    Test.eq(payload.model, 'model', 'payload model')
    Test.eq(payload.stream, false, 'payload stream flag')
    Test.eq(payload.temperature, 0.1, 'payload temperature')
    Test.eq(#payload.tools, 1, 'tools are included')
    Test.eq(payload.tool_choice, 'auto', 'tool choice is included')
    Test.eq(payload.parallel_tool_calls, false, 'parallel tool calls flag is included')
    Test.truthy(payload.extra, 'additional params are merged')

    local plain = Protocol.build_payload({
        messages = {},
    }, {
        openai_model = 'model',
        stream = true,
    })
    Test.eq(plain.tools, nil, 'tools are omitted when not provided')
    Test.eq(plain.stream_options.include_usage, true, 'stream usage is requested')
end

do
    local buffer = Protocol.new_tool_call_buffer()

    buffer:push({
        { index = 0, id = 'call_a', type = 'function', ['function'] = { name = 'read_file', arguments = '{"pa' } },
    })
    buffer:push({
        { index = 0, ['function'] = { arguments = 'th":"a.txt"}' } },
    })
    buffer:push({
        { index = 1, id = 'call_b', ['function'] = { name = 'list_directory', arguments = '' } },
        { index = 1, ['function'] = { arguments = '{"include_hidden":true}' } },
    })

    local calls = buffer:list()
    Test.eq(#calls, 2, 'both streamed tool calls are assembled')
    Test.eq(calls[1].id, 'call_a', 'first tool call id')
    Test.eq(calls[1]['function'].name, 'read_file', 'first tool call name')
    Test.eq(calls[1]['function'].arguments, '{"path":"a.txt"}', 'fragmented arguments are joined')
    Test.eq(calls[2].id, 'call_b', 'second tool call id')
    Test.eq(calls[2]['function'].arguments, '{"include_hidden":true}', 'second arguments are joined')
end

do
    local buffer = Protocol.new_tool_call_buffer()
    buffer:push({
        { ['function'] = { name = 'read_file', arguments = '{}' } },
    })

    local calls = buffer:list()
    Test.eq(#calls, 1, 'tool calls without an index still work')
    Test.eq(calls[1].id, 'call_1', 'missing ids are generated')
end

do
    local value = {
        choices = {
            {
                finish_reason = 'tool_calls',
                message = {
                    content = 'checking',
                    tool_calls = {
                        {
                            id = 'x',
                            type = 'function',
                            ['function'] = { name = 'write_file', arguments = { path = 'a.txt', content = 'x' } },
                        },
                    },
                },
            },
        },
        usage = { prompt_tokens = 3, completion_tokens = 2, total_tokens = 5 },
    }

    Test.eq(Protocol.extract_content(value), 'checking', 'non-stream content is extracted')
    Test.eq(Protocol.finish_reason(value), 'tool_calls', 'finish reason is extracted')

    local calls = Protocol.extract_tool_calls(value)
    Test.eq(#calls, 1, 'non-stream tool calls are extracted')
    local decoded = vim.json.decode(calls[1]['function'].arguments)
    Test.eq(decoded.path, 'a.txt', 'table arguments are encoded (path)')
    Test.eq(decoded.content, 'x', 'table arguments are encoded (content)')

    Test.eq(Protocol.extract_usage(value), { total_tokens = 5, input = 3, output = 2 }, 'usage is extracted')
    Test.eq(Protocol.extract_error({ error = { message = 'boom' } }), 'boom', 'errors are extracted')
    Test.eq(Protocol.extract_error({ message = 'plain' }), 'plain', 'plain error messages are extracted')
end

do
    local calls = Protocol.extract_tool_calls({
        choices = {
            {
                message = {
                    tool_calls = {
                        { type = 'function', ['function'] = { name = 'read_file', arguments = '{}' } },
                    },
                },
            },
        },
    })
    Test.eq(#calls, 1, 'non-stream tool calls may omit an id')
    Test.eq(calls[1].id, 'call_1', 'missing non-stream ids are generated')
end

do
    Test.eq(#Protocol.extract_tool_calls({}), 0, 'missing choices yield no tool calls')
    Test.eq(Protocol.extract_content({}), nil, 'missing content is nil')
    Test.eq(Protocol.finish_reason({}), nil, 'missing finish reason is nil')
end
