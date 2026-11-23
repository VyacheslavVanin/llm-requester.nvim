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
