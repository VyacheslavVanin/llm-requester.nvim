local Compaction = require('llm-requester.chat.compaction')
local Session = require('llm-requester.chat.session')

local Test = _G.Test

local function call(id, name, arguments)
    return {
        id = id,
        type = 'function',
        ['function'] = { name = name, arguments = arguments or '{}' },
    }
end

local function config(overrides)
    return vim.tbl_deep_extend('force', {
        openai_model = 'test-model',
        stream = true,
        compaction = {
            enabled = true,
            auto = true,
            threshold = 0.9,
            max_context_tokens = 128000,
            keep_recent_tokens = 8000,
            max_summary_tokens = 1500,
            max_message_chars = 4000,
        },
    }, overrides or {})
end

do
    Test.eq(Compaction.is_enabled({ compaction = { enabled = false } }), false, 'compaction can be disabled')
    Test.eq(Compaction.is_enabled({}), true, 'compaction is enabled by default')
    Test.eq(Compaction.is_auto_enabled({ compaction = { auto = false } }), false, 'auto compaction can be disabled')
    Test.eq(Compaction.is_auto_enabled({ compaction = { enabled = false } }), false, 'disabled compaction is not automatic')

    Test.truthy(
        Compaction.format_progress(3):find('3 messages', 1, true),
        'the progress notice includes the message count'
    )
    Test.eq(Compaction.format_progress(), '[compacting context...]', 'the generic progress notice')
    Test.truthy(Compaction.format_failure('boom'):find('boom', 1, true), 'the failure notice includes the error')
    Test.truthy(
        Compaction.format_notice({ summarized = 1, before_tokens = 10, after_tokens = 5 }):find(
            '1 messages summarized, ~10 -> ~5 tokens',
            1,
            true
        ),
        'the result notice reports the statistics'
    )
end

do
    Test.eq(Compaction.estimate_text_tokens(''), 0, 'empty text has no tokens')
    Test.eq(Compaction.estimate_text_tokens('abcd'), 1, 'four characters are one token')
    Test.eq(Compaction.estimate_text_tokens('abcde'), 2, 'partial tokens round up')

    local messages = {
        { role = 'user', content = 'abcd' },
        {
            role = 'assistant',
            content = '',
            tool_calls = { call('c1', 'read_file', '{"path":"a.lua"}') },
        },
    }
    Test.truthy(
        Compaction.estimate_messages_tokens(messages) > 8,
        'tool calls contribute to the estimate'
    )
end

do
    local session = Session.new({
        id = 'plan-session',
        messages = {
            { role = 'user', content = 'initial task ' .. string.rep('a', 400) },
            { role = 'assistant', content = 'old answer ' .. string.rep('b', 400) },
            { role = 'user', content = 'my remark' },
            {
                role = 'assistant',
                content = '',
                tool_calls = { call('c1', 'read_file', '{"path":"a.lua"}') },
            },
            { role = 'tool', tool_call_id = 'c1', name = 'read_file', content = 'line one\nline two' },
            { role = 'assistant', content = 'final old answer' },
            { role = 'user', content = 'latest question' },
        },
    })

    local plan = Compaction.plan(session, config({
        compaction = { keep_recent_tokens = 40 },
    }))

    Test.truthy(plan, 'a plan is produced when older messages can be dropped')
    Test.truthy(plan.task.content:find('initial task', 1, true), 'the original task is identified')
    Test.eq(plan.messages[1], plan.task, 'the original task starts the compacted history')
    Test.eq(plan.dropped_count, 2, 'old assistant and user messages are summarized')
    Test.eq(plan.dropped[1].role, 'assistant', 'old assistant message is dropped')
    Test.eq(plan.dropped[2].content, 'my remark', 'older user remark is summarized')
    Test.eq(plan.messages[2].role, 'assistant', 'tail starts at a safe message')
    Test.truthy(plan.messages[2].tool_calls, 'tool call stays with its result')
    Test.eq(plan.messages[3].role, 'tool', 'tool result stays next to the call')
    Test.eq(plan.messages[#plan.messages].content, 'latest question', 'last message is kept verbatim')

    local untouched = Compaction.plan(session, config({
        compaction = { keep_recent_tokens = 100000 },
    }))
    Test.eq(untouched, nil, 'nothing is dropped when the whole history fits the tail')
end

do
    local session = Session.new({
        id = 'plan-tool-boundary',
        messages = {
            { role = 'user', content = 'task' },
            {
                role = 'assistant',
                content = '',
                tool_calls = { call('c1', 'read_file', '{}') },
            },
            { role = 'tool', tool_call_id = 'c1', content = 'result' },
            { role = 'user', content = string.rep('x', 400) },
        },
    })

    local plan = Compaction.plan(session, config({
        compaction = { keep_recent_tokens = 1 },
    }))

    Test.truthy(plan, 'tool-only turns can be compacted')
    Test.truthy(
        plan.messages[2].role ~= 'tool',
        'the compacted history never starts its tail with an orphan tool result'
    )
end

do
    local session = Session.new({
        id = 'estimate-session',
        messages = { { role = 'user', content = string.rep('x', 400) } },
    })
    session:set_context_tokens(500, 1)

    local tokens = Compaction.current_tokens(session, { system_prompt = 'SYS' })
    Test.truthy(tokens >= 500, 'provider usage is respected')

    session:add_user(string.rep('y', 400))
    local grown = Compaction.current_tokens(session, { system_prompt = 'SYS' })
    Test.truthy(grown >= tokens + 90, 'messages added after the measurement are estimated')

    local reached = Compaction.should_compact(session, config({
        compaction = { max_context_tokens = 600, threshold = 0.9 },
    }), { system_prompt = 'SYS' })
    Test.truthy(reached, 'the threshold is reached for a small context window')
end

do
    local calls = {}
    local function fake_request(options)
        table.insert(calls, options)
        vim.schedule(function()
            options.on_finish('## Goal\ndo the task\n\n## Plan and progress\n1. done')
        end)
        return { kill = function() end }
    end

    local session = Session.new({
        id = 'compact-session',
        messages = {
            { role = 'user', content = 'original task' },
            { role = 'assistant', content = string.rep('b', 800) },
            { role = 'user', content = 'my remark' },
            { role = 'user', content = 'latest question' },
        },
    })

    local done, ok, result = false, nil, nil
    local job = Compaction.compact(session, config({
        compaction = { keep_recent_tokens = 30 },
    }), {
        system_prompt = 'SYSTEM',
        request = fake_request,
    }, function(success, value)
        ok = success
        result = value
        done = true
    end)

    Test.truthy(job, 'compaction returns a cancellable handle')
    Test.truthy(Test.wait_for(function()
        return done
    end), 'compaction finishes')

    Test.eq(ok, true, 'successful compaction reports success')
    Test.eq(result.summarized, 1, 'one old message is summarized')
    Test.eq(#calls, 1, 'one summarization request is made')
    Test.eq(calls[1].config.stream, false, 'the summarization request is not streamed')
    Test.eq(calls[1].tools, nil, 'no tools are sent to the summarizer')
    Test.eq(calls[1].messages[1].role, 'system', 'summarizer system prompt is a system message')
    Test.truthy(
        calls[1].messages[1].content:find('working memory', 1, true),
        'the summarizer receives the working-memory instructions'
    )
    Test.truthy(
        calls[1].messages[2].content:find('original task', 1, true),
        'the original task is given to the summarizer'
    )
    Test.truthy(
        calls[1].messages[2].content:find('[assistant]', 1, true),
        'the dropped assistant content is given to the summarizer'
    )

    Test.eq(session.messages[1].content, 'original task', 'the original task is preserved verbatim')
    Test.eq(#session.messages, 3, 'dropped messages are removed')
    Test.truthy(session.compaction, 'the summary is stored on the session')
    Test.truthy(session.compaction.summary:find('## Plan and progress', 1, true), 'summary text is stored')
    Test.eq(session.compaction.compacted_messages, 1, 'summarized message count is stored')
    Test.eq(session.compaction.model, 'test-model', 'the summarizer model is stored')
    Test.eq(session.context_tokens, nil, 'the measured context is reset after compaction')

    local built = session:build_messages('SYSTEM', 'CONTEXT')
    Test.eq(built[1], { role = 'system', content = 'SYSTEM' }, 'system prompt stays first')
    Test.truthy(
        built[2].role == 'system' and built[2].content:find('## Plan and progress', 1, true),
        'the summary is injected as a system message'
    )
    Test.eq(built[3].role, 'system', 'editor context follows the summary')
    Test.eq(built[4].content, 'original task', 'preserved task follows the context')
end

do
    local calls = {}
    local function fake_request(options)
        table.insert(calls, options)
        vim.schedule(function()
            options.on_finish('NEW SUMMARY')
        end)
        return { kill = function() end }
    end

    local session = Session.new({
        id = 'merge-session',
        messages = {
            { role = 'user', content = 'task' },
            { role = 'assistant', content = string.rep('a', 800) },
            { role = 'user', content = 'latest' },
        },
    })
    session.compaction = {
        summary = 'OLD SUMMARY',
        updated_at = 1,
        compacted_messages = 4,
    }

    local done, ok = false, nil
    Compaction.compact(session, config({
        compaction = { keep_recent_tokens = 20 },
    }), {
        system_prompt = 'SYSTEM',
        request = fake_request,
    }, function(success)
        ok = success
        done = true
    end)

    Test.truthy(Test.wait_for(function()
        return done
    end), 'merge compaction finishes')
    Test.eq(ok, true, 'merge compaction succeeds')
    Test.truthy(
        calls[1].messages[2].content:find('OLD SUMMARY', 1, true),
        'the previous summary is merged'
    )
    Test.eq(session.compaction.summary, 'NEW SUMMARY', 'the summary is replaced')
    Test.eq(session.compaction.compacted_messages, 5, 'the summarized count accumulates')
end

do
    local calls = {}
    local function fake_request(options)
        table.insert(calls, options)
        local number = #calls
        vim.schedule(function()
            options.on_finish('SUMMARY ' .. number)
        end)
        return { kill = function() end }
    end

    local session = Session.new({
        id = 'chunk-session',
        messages = {
            { role = 'user', content = 'task' },
            { role = 'assistant', content = string.rep('a', 4000) },
            { role = 'assistant', content = string.rep('b', 4000) },
            { role = 'user', content = 'latest' },
        },
    })

    local done, ok, result = false, nil, nil
    Compaction.compact(session, config({
        compaction = {
            max_context_tokens = 1000,
            max_summary_tokens = 100,
            keep_recent_tokens = 1,
        },
    }), {
        system_prompt = 'SYSTEM',
        request = fake_request,
    }, function(success, value)
        ok = success
        result = value
        done = true
    end)

    Test.truthy(Test.wait_for(function()
        return done
    end), 'chunked compaction finishes')
    Test.eq(ok, true, 'chunked compaction succeeds')
    Test.truthy(#calls >= 2, 'oversized prefixes are summarized in chunks')
    Test.truthy(result.chunks >= 2, 'the chunk count is reported')
    Test.truthy(
        calls[2].messages[2].content:find('SUMMARY 1', 1, true),
        'later chunks receive the running summary'
    )
    Test.eq(session.compaction.summary, 'SUMMARY ' .. #calls, 'the final chunk summary is stored')
end

do
    local calls = {}
    local function fake_request(options)
        table.insert(calls, options)
        vim.schedule(function()
            options.on_finish('SUMMARY')
        end)
        return { kill = function() end }
    end

    local session = Session.new({
        id = 'utf8-session',
        messages = {
            { role = 'user', content = 'task' },
            { role = 'assistant', content = string.rep('привет ', 800) },
            { role = 'user', content = 'latest' },
        },
    })

    local done = false
    Compaction.compact(session, config({
        compaction = {
            max_context_tokens = 1000,
            max_summary_tokens = 100,
            max_message_chars = 10000,
            keep_recent_tokens = 1,
        },
    }), {
        system_prompt = 'SYSTEM',
        request = fake_request,
    }, function()
        done = true
    end)

    Test.truthy(Test.wait_for(function()
        return done
    end), 'UTF-8 chunked compaction finishes')
    Test.truthy(#calls >= 2, 'a long UTF-8 message is split into chunks')

    for index, call in ipairs(calls) do
        local fragment = call.messages[2].content:match(
            'Conversation fragment to merge into the summary:\n(.*)$'
        )
        Test.truthy(fragment, 'the fragment is rendered for chunk ' .. index)
        local first = fragment:byte(1)
        Test.falsy(
            first ~= nil and first >= 0x80 and first <= 0xBF,
            'chunk ' .. index .. ' does not start in the middle of a UTF-8 character'
        )
    end
end

do
    local function fake_request(options)
        vim.schedule(function()
            options.on_error('provider is down')
        end)
        return { kill = function() end }
    end

    local session = Session.new({
        id = 'failure-session',
        messages = {
            { role = 'user', content = 'task' },
            { role = 'assistant', content = string.rep('a', 800) },
            { role = 'user', content = 'latest' },
        },
    })

    local done, ok, result = false, nil, nil
    Compaction.compact(session, config({
        compaction = { keep_recent_tokens = 20 },
    }), {
        system_prompt = 'SYSTEM',
        request = fake_request,
    }, function(success, value)
        ok = success
        result = value
        done = true
    end)

    Test.truthy(Test.wait_for(function()
        return done
    end), 'failed compaction finishes')
    Test.eq(ok, false, 'failed compaction reports failure')
    Test.truthy(tostring(result):find('provider is down', 1, true), 'the provider error is reported')
    Test.eq(session.compaction, nil, 'a failed compaction does not store a summary')
    Test.eq(#session.messages, 3, 'a failed compaction leaves the history untouched')
end

do
    local session = Session.new({
        id = 'skip-session',
        messages = { { role = 'user', content = 'only message' } },
    })

    local done, ok, result = false, nil, nil
    Compaction.compact(session, config(), {
        request = function()
            Test.fail('no request is expected when nothing can be compacted')
            return nil
        end,
    }, function(success, value)
        ok = success
        result = value
        done = true
    end)

    Test.truthy(Test.wait_for(function()
        return done
    end), 'skip callback is scheduled')
    Test.eq(ok, true, 'skipping is not an error')
    Test.eq(result.skipped, true, 'the skip is reported')
    Test.eq(result.reason, 'nothing to compact', 'the skip reason is reported')
end

do
    local session = Session.new({
        id = 'cancel-session',
        messages = {
            { role = 'user', content = 'task' },
            { role = 'assistant', content = string.rep('a', 800) },
            { role = 'user', content = 'latest' },
        },
    })

    local finished = false
    local killed = false
    local function fake_request()
        return {
            kill = function()
                killed = true
            end,
        }
    end

    local job = Compaction.compact(session, config({
        compaction = { keep_recent_tokens = 20 },
    }), {
        system_prompt = 'SYSTEM',
        request = fake_request,
    }, function()
        finished = true
    end)

    job:kill(9)

    Test.truthy(killed, 'cancelling kills the summarization process')
    Test.falsy(finished, 'a cancelled compaction does not call back')
    Test.eq(session.compaction, nil, 'a cancelled compaction leaves the session untouched')
end
