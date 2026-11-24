local Session = require('llm-requester.chat.session')

local Test = _G.Test

do
    local session = Session.new({
        id = 'session-1',
        cwd = '/project',
        messages = {
            { role = 'system', content = 'must be dropped' },
            { role = 'user', content = 'hello' },
            { role = 'assistant', content = 'hi' },
            { role = 'tool', content = 'must be dropped' },
            { role = 'user', content = 42 },
        },
    })

    Test.eq(#session.messages, 2, 'only valid user/assistant messages are loaded')
    Test.eq(session.messages[1].content, 'hello', 'user message content')
    Test.eq(session.messages[2].content, 'hi', 'assistant message content')
end

do
    local session = Session.new({ id = 'session-2', cwd = '/project' })

    session:add_user('question')
    session:add_assistant('answer')
    session:add_assistant('')

    Test.eq(#session.messages, 2, 'empty assistant messages are ignored')

    local messages = session:build_messages('SYSTEM', 'context')

    Test.eq(#messages, 4, 'request contains system, context and history')
    Test.eq(messages[1], { role = 'system', content = 'SYSTEM' }, 'system prompt')
    Test.eq(messages[2], { role = 'system', content = 'additional_context:\ncontext' }, 'editor context')
    Test.eq(messages[3], { role = 'user', content = 'question' }, 'user message')
    Test.eq(messages[4], { role = 'assistant', content = 'answer' }, 'assistant message')
end

do
    local session = Session.new({ id = 'session-3' })

    session:add_usage({ total_tokens = 10, input = 6, output = 4 })
    session:add_usage({ total_tokens = 5, input = 3, output = 2 })
    session:add_usage(nil)

    Test.eq(session.usage, { total_tokens = 15, input = 9, output = 6 }, 'usage is accumulated')
end

do
    local session = Session.new({ id = 'session-remove' })

    session:add_user('keep me')
    session:add_user('stop me')

    Test.eq(session:remove_last_user('different text'), nil, 'mismatched content is not removed')
    Test.eq(session:remove_last_user('stop me'), 'stop me', 'last user message is removed')
    Test.eq(#session.messages, 1, 'only the last user message is removed')
    Test.eq(session.messages[1].content, 'keep me', 'earlier messages are preserved')
    Test.eq(session:remove_last_user(), 'keep me', 'remaining last user can be removed')
    Test.eq(session:remove_last_user(), nil, 'nothing to remove after rollback')
end

do
    local session = Session.new({ id = 'session-tools', cwd = '/project', mode = 'agent' })

    session:add_user('fix the bug')
    session:add_assistant('', {
        { id = 'call_1', type = 'function', ['function'] = { name = 'read_file', arguments = '{"path":"a.lua"}' } },
    })
    session:add_tool_result('call_1', '1: return 1', 'read_file')
    session:add_assistant('done')

    Test.eq(#session.messages, 4, 'tool exchange is stored')
    Test.eq(session.mode, 'agent', 'agent mode is stored')
    Test.eq(session.messages[2].content, '', 'assistant tool call may have empty content')
    Test.eq(session.messages[2].tool_calls[1].id, 'call_1', 'tool call id is stored')
    Test.eq(session.messages[3].tool_call_id, 'call_1', 'tool result references the call')
    Test.eq(session.messages[3].name, 'read_file', 'tool result keeps the tool name')

    local restored = Session.from_table(session:to_table())
    Test.truthy(restored, 'agent session roundtrip succeeds')
    Test.eq(restored.mode, 'agent', 'agent mode survives roundtrip')
    Test.eq(restored.messages, session.messages, 'tool messages survive roundtrip')

    local messages = restored:build_messages('SYSTEM', nil)
    Test.eq(messages[3].tool_calls[1]['function'].name, 'read_file', 'tool calls are sent to the LLM')
    Test.eq(messages[4].tool_call_id, 'call_1', 'tool results are sent to the LLM')
end

do
    local session = Session.new({ id = 'session-rollback', mode = 'agent' })

    session:add_user('first')
    session:add_assistant('first answer')
    session:add_user('second')
    session:add_assistant('', {
        { id = 'call_1', type = 'function', ['function'] = { name = 'read_file', arguments = '{}' } },
    })
    session:add_tool_result('call_1', 'result', 'read_file')

    Test.eq(session:rollback_pending_request(), 'second', 'rollback returns the stopped question')
    Test.eq(#session.messages, 2, 'rollback removes tool calls and results of the exchange')
    Test.eq(session.messages[2].content, 'first answer', 'earlier history is preserved')
    Test.eq(session:rollback_pending_request(), 'first', 'rollback can remove earlier exchanges')
    Test.eq(session:rollback_pending_request(), nil, 'rollback on empty history returns nil')
end

do
    local session = Session.new({
        id = 'session-tool-normalization',
        messages = {
            { role = 'tool', content = 'missing id' },
            { role = 'tool', tool_call_id = 'x', content = 'ok' },
            { role = 'assistant', content = '', tool_calls = { { id = 'a', ['function'] = { arguments = '{}' } } } },
            { role = 'assistant', content = 'text', tool_calls = { { id = 'b', type = 'function', ['function'] = { name = 'read_file', arguments = 42 } } } },
        },
    })

    Test.eq(#session.messages, 2, 'invalid messages are dropped')
    Test.eq(session.messages[1].role, 'tool', 'valid tool result is kept')
    Test.eq(session.messages[2].tool_calls[1].id, 'b', 'valid tool call is kept')
    Test.eq(session.messages[2].tool_calls[1]['function'].arguments, '', 'non-string arguments are normalized')
end

do
    local session = Session.new({
        id = 'session-4',
        cwd = '/project',
        created_at = 100,
        updated_at = 200,
        model = 'model',
        messages = { { role = 'user', content = 'hello' } },
        usage = { total_tokens = 10, input = 6, output = 4 },
    })

    local restored = Session.from_table(session:to_table())

    Test.truthy(restored, 'session roundtrip succeeds')
    Test.eq(restored.id, 'session-4', 'session id')
    Test.eq(restored.cwd, '/project', 'session cwd')
    Test.eq(restored.created_at, 100, 'created_at')
    Test.eq(restored.updated_at, 200, 'updated_at')
    Test.eq(restored.messages, session.messages, 'messages')
    Test.eq(restored.usage, session.usage, 'usage')

    Test.eq(Session.from_table({}), nil, 'invalid session is rejected')
    Test.eq(Session.from_table({ id = 'x', messages = 'nope' }), nil, 'invalid messages are rejected')
end

do
    local session = Session.new({
        id = 'session-compaction',
        messages = {
            { role = 'user', content = 'task' },
            { role = 'user', content = 'latest' },
        },
        compaction = {
            summary = 'a summary',
            updated_at = 10,
            compacted_messages = 3,
            model = 'model',
        },
        context_tokens = 120,
        context_messages = 4,
    })

    Test.eq(session.version, 3, 'new sessions use the current format version')
    Test.eq(session.compaction.summary, 'a summary', 'compaction summary is loaded')
    Test.eq(session.context_tokens, 120, 'measured context tokens are loaded')
    Test.eq(session.context_messages, 4, 'measured context message count is loaded')

    local restored = Session.from_table(session:to_table())
    Test.truthy(restored, 'session with compaction roundtrips')
    Test.eq(restored.compaction, session.compaction, 'compaction survives roundtrip')
    Test.eq(restored.context_tokens, 120, 'context tokens survive roundtrip')
    Test.eq(restored.context_messages, 4, 'context message count survives roundtrip')

    local built = restored:build_messages('SYSTEM', 'CONTEXT')
    Test.eq(#built, 5, 'summary and context are added to the request')
    Test.eq(built[1].content, 'SYSTEM', 'system prompt comes first')
    Test.eq(built[2].role, 'system', 'summary is a system message')
    Test.truthy(built[2].content:find('a summary', 1, true), 'summary content is injected')
    Test.eq(built[3].content, 'additional_context:\nCONTEXT', 'editor context follows the summary')
    Test.eq(built[4].content, 'task', 'history follows the injected messages')

    Test.eq(Session.from_table({
        id = 'bad-compaction',
        messages = {},
        compaction = { summary = '' },
        context_tokens = -1,
    }).compaction, nil, 'empty summaries are rejected')
end

do
    local session = Session.new({
        id = 'session-apply-compaction',
        messages = {
            { role = 'user', content = 'task' },
            { role = 'assistant', content = 'old' },
            { role = 'user', content = 'latest' },
        },
    })
    session:set_context_tokens(2000, 3)

    local applied = session:apply_compaction('summary text', {
        { role = 'user', content = 'task' },
        { role = 'user', content = 'latest' },
    }, { compacted_messages = 1, model = 'model' })

    Test.eq(applied, true, 'compaction is applied')
    Test.eq(#session.messages, 2, 'compacted messages replace the history')
    Test.eq(session.compaction.summary, 'summary text', 'summary is stored')
    Test.eq(session.compaction.compacted_messages, 1, 'summarized count is stored')
    Test.eq(session.compaction.model, 'model', 'model is stored')
    Test.eq(session.context_tokens, nil, 'measured context is reset')
    Test.eq(session.context_messages, nil, 'measured message count is reset')

    session:apply_compaction('second summary', { { role = 'user', content = 'task' } }, {
        compacted_messages = 2,
    })
    Test.eq(session.compaction.compacted_messages, 3, 'summarized count accumulates')
    Test.eq(session.compaction.summary, 'second summary', 'summary is replaced')

    Test.eq(
        session:apply_compaction('', {}, {}),
        false,
        'an empty summary is not applied'
    )
    Test.eq(
        session:apply_compaction('text', 'not a table', {}),
        false,
        'invalid messages are not applied'
    )
end
