-- Runs last: it replaces the transport module with a fake before Agent loads.

local queue = {}
local requests = {}

local fake_client = {}

function fake_client.request(options)
    table.insert(requests, options)

    local step = table.remove(queue, 1)
    vim.schedule(function()
        if not step then
            options.on_error('fake client ran out of steps', '')
        elseif step.tool_calls then
            options.on_finish(step.content or '', step.tool_calls, 'tool_calls')
        else
            options.on_finish(step.content or '', {}, 'stop')
        end
    end)

    return {
        kill = function() end,
    }
end

package.loaded['llm-requester.chat.client'] = fake_client

local Agent = require('llm-requester.chat.agent')
local Session = require('llm-requester.chat.session')
local Test = _G.Test
local uv = vim.uv or vim.loop

local base = vim.fn.tempname() .. '-llm-requester-agent'
vim.fn.mkdir(base .. '/sub', 'p')
vim.fn.writefile({ 'line one', 'line two' }, base .. '/file.txt')
local root = uv.fs_realpath(base)

local function call(id, name, arguments)
    return {
        id = id,
        type = 'function',
        ['function'] = { name = name, arguments = vim.json.encode(arguments or {}) },
    }
end

local function new_agent(overrides)
    local agent_config = vim.tbl_deep_extend('force', {
        max_tool_iterations = 8,
        max_stored_tool_output = 1000,
        confirm = function(_, _, callback)
            callback('once')
        end,
        confirm_iteration_limit = function(_, _, callback)
            callback('stop')
        end,
    }, overrides or {})

    local session = Session.new({ id = 'agent-session', cwd = root, mode = 'agent' })
    session:add_user('inspect the project')

    return Agent.new({
        session = session,
        config = {
            openai_url = 'http://localhost',
            openai_model = 'model',
            stream = false,
            agent = agent_config,
        },
    }), session
end

local function run(agent, events)
    local done = false
    local finished = nil
    local failed = nil

    events.on_finish = function(content)
        finished = content
        done = true
    end
    events.on_error = function(message)
        failed = message
        done = true
    end

    agent:send(events, '')
    vim.wait(5000, function()
        return done
    end)

    return finished, failed
end

do
    requests = {}
    queue = {
        { content = 'let me look', tool_calls = { call('c1', 'read_file', { path = 'file.txt' }) } },
        { content = 'all done' },
    }

    local agent, session = new_agent()
    local tool_started = false
    local tool_result = nil

    local finished, failed = run(agent, {
        on_tool_start = function()
            tool_started = true
        end,
        on_tool_result = function(_, result)
            tool_result = result
        end,
    })

    Test.truthy(tool_started, 'tool calls are reported to the UI')
    Test.truthy(tool_result and tool_result:find('line one', 1, true), 'tool result is returned to the UI')
    Test.eq(finished, 'all done', 'final assistant reply completes the exchange')
    Test.eq(failed, nil, 'successful exchange has no error')
    Test.eq(#requests, 2, 'one tool round and one final round are requested')
    Test.truthy(#requests[1].tools > 0, 'tool declarations are sent on the first request')
    Test.truthy(#requests[2].tools > 0, 'tool declarations are sent on later requests')

    local second_messages = requests[2].messages
    local has_tool_call = false
    local has_tool_result = false
    for _, message in ipairs(second_messages) do
        if message.role == 'assistant' and message.tool_calls then
            has_tool_call = true
        end
        if message.role == 'tool' and message.tool_call_id == 'c1' then
            has_tool_result = true
        end
    end
    Test.truthy(has_tool_call, 'assistant tool call is sent back to the model')
    Test.truthy(has_tool_result, 'tool result is sent back to the model')

    Test.eq(#session.messages, 4, 'user, tool call, tool result and final reply are stored')
    Test.eq(session.messages[2].tool_calls[1].id, 'c1', 'stored tool call id')
    Test.eq(session.messages[3].role, 'tool', 'stored tool result role')
    Test.eq(session.messages[4].content, 'all done', 'stored final reply')
end

do
    requests = {}
    queue = {
        { tool_calls = { call('c2', 'write_file', { path = 'file.txt', content = 'nope' }) } },
        { content = 'ok' },
    }

    local agent, session = new_agent({
        confirm = function(_, _, callback)
            callback('deny')
        end,
    })

    local finished = run(agent, {})

    Test.eq(finished, 'ok', 'agent continues after a denied tool')
    Test.eq(#requests, 2, 'denied tool still triggers the next round')
    Test.truthy(session.messages[3].content:find('write denied', 1, true), 'denial is reported to the model')
end

do
    requests = {}
    queue = {
        { tool_calls = { call('c3', 'read_file', { path = 'file.txt' }) } },
    }

    local notices = {}
    local agent, session = new_agent({ max_tool_iterations = 1 })
    local finished, failed = run(agent, {
        on_notice = function(message)
            table.insert(notices, message)
        end,
    })

    Test.eq(failed, nil, 'iteration limit is not reported as an error')
    Test.eq(finished, '', 'stopping at the limit finishes the exchange')
    Test.eq(#requests, 1, 'stopping at the limit prevents further requests')

    local notice_text = table.concat(notices, '\n')
    Test.truthy(notice_text:find('iteration limit reached', 1, true), 'limit prompt is announced')
    Test.truthy(notice_text:find('stopped at the tool iteration limit', 1, true), 'stop reason is announced')
    Test.truthy(session.messages[3].content:find('chose to stop', 1, true), 'limit is stored as a tool error')
end

do
    requests = {}
    queue = {
        { tool_calls = { call('c7', 'read_file', { path = 'file.txt' }) } },
        { content = 'after continue' },
    }

    local notices = {}
    local agent, session = new_agent({
        max_tool_iterations = 1,
        iteration_limit_step = 2,
        confirm_iteration_limit = function(_, _, callback)
            callback('continue')
        end,
    })
    local finished = run(agent, {
        on_notice = function(message)
            table.insert(notices, message)
        end,
    })

    Test.eq(finished, 'after continue', 'agent continues after approving more rounds')
    Test.eq(#requests, 2, 'continued agent performs the next request')
    Test.truthy(table.concat(notices, '\n'):find('raised to 3', 1, true), 'new limit is announced')
    Test.eq(session.messages[3].role, 'tool', 'tool is executed after continuation')
    Test.truthy(session.messages[3].content:find('line one', 1, true), 'tool result is stored after continuation')
end

do
    requests = {}
    queue = {
        {
            tool_calls = {
                call('c5', 'read_file', { path = 'file.txt' }),
                call('c6', 'read_file', { path = 'file.txt' }),
            },
        },
        { content = 'done' },
    }

    local agent, session = new_agent({ max_tool_calls_per_round = 1 })
    local finished = run(agent, {})

    Test.eq(finished, 'done', 'agent continues after the per-round call limit')
    Test.eq(session.messages[3].tool_call_id, 'c5', 'first tool call is executed')
    Test.truthy(session.messages[4].content:find('too many tool calls', 1, true), 'extra calls are rejected')
end

do
    requests = {}
    queue = {
        { tool_calls = { call('c4', 'read_file', { path = 'file.txt' }) } },
        { content = 'ignored' },
    }

    local agent, session = new_agent()
    local pending = false
    agent:send({}, '')

    Test.truthy(agent:is_pending(), 'agent is pending before cancellation')
    agent:cancel()
    vim.wait(50, function()
        return false
    end)
    Test.falsy(agent:is_pending(), 'cancel clears the pending flag')
    Test.eq(#requests, 1, 'cancel prevents the next request')
    Test.eq(#session.messages, 1, 'cancel lets Chat roll the exchange back')
end

do
    requests = {}
    queue = {
        { content = 'fake summary' },
        { content = 'after compaction' },
    }

    local session = Session.new({ id = 'agent-compaction', cwd = root, mode = 'agent' })
    session:add_user('original task')
    session:add_assistant(string.rep('old work ', 200))
    session:add_user('latest question')

    local agent = Agent.new({
        session = session,
        config = {
            openai_url = 'http://localhost',
            openai_model = 'model',
            stream = false,
            agent = {
                max_tool_iterations = 8,
                system_prompt = 'agent system prompt',
            },
            compaction = {
                enabled = true,
                auto = true,
                threshold = 0.1,
                max_context_tokens = 1000,
                keep_recent_tokens = 20,
                max_summary_tokens = 100,
            },
        },
    })

    local notices = {}
    local finished = run(agent, {
        on_notice = function(message)
            table.insert(notices, message)
        end,
    })

    Test.eq(finished, 'after compaction', 'the exchange continues after compaction')
    Test.eq(#requests, 2, 'a summary request is followed by the normal agent request')
    Test.eq(#requests[1].messages, 2, 'the summary request has system and user messages only')
    Test.eq(requests[1].tools, nil, 'the summary request does not declare tools')
    Test.truthy(
        requests[1].messages[2].content:find('original task', 1, true),
        'the original task is passed to the summarizer'
    )
    Test.eq(requests[1].config.stream, false, 'the summary request is not streamed')

    local injected = false
    for _, message in ipairs(requests[2].messages) do
        if message.role == 'system' and tostring(message.content):find('fake summary', 1, true) then
            injected = true
        end
    end
    Test.truthy(injected, 'the summary is injected into the next agent request')
    Test.truthy(#requests[2].tools > 0, 'tool declarations are kept after compaction')
    Test.eq(session.messages[1].content, 'original task', 'the original task is kept verbatim')
    Test.eq(session.compaction.summary, 'fake summary', 'the summary is stored on the session')
    Test.truthy(
        table.concat(notices, '\n'):find('context compacted', 1, true),
        'compaction is announced in the chat'
    )
end

vim.fn.delete(base, 'rf')
