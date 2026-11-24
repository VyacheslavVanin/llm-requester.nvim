-- Runs after agent_spec: the chat module is loaded here with a fake transport
-- so manual and automatic compaction can be exercised end to end.

local requests = {}

local fake_client = {}

function fake_client.request(options)
    table.insert(requests, options)

    vim.schedule(function()
        if options.tools == nil and options.config.stream == false then
            options.on_finish('FAKE SUMMARY')
        else
            options.on_finish('fake reply')
        end
    end)

    return { kill = function() end }
end

package.loaded['llm-requester.chat.client'] = fake_client

local Chat = require('llm-requester.chat')
local Ui = require('llm-requester.chat.ui')
local Test = _G.Test

local dir = vim.fn.tempname() .. '-llm-requester-chat-compaction'
vim.fn.mkdir(dir, 'p')

local function write_session(id, updated_at, messages)
    local path = dir .. '/' .. id .. '.json'
    vim.fn.writefile({
        vim.json.encode({
            version = 3,
            id = id,
            created_at = os.time(),
            updated_at = updated_at,
            cwd = vim.fn.getcwd(),
            mode = 'chat',
            messages = messages,
        }),
    }, path)
    return path
end

local function read_session(path)
    return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
end

local auto_path = write_session('auto-session', os.time(), {
    { role = 'user', content = 'original task' },
    { role = 'assistant', content = string.rep('old work ', 200) },
    { role = 'user', content = 'latest question' },
})

-- Automatic compaction: the send must compact first and the summary must
-- reach the provider with the normal request.
Chat.setup({
    sessions_dir = dir,
    continue_last_session = true,
    compaction = {
        enabled = true,
        auto = true,
        threshold = 0.1,
        max_context_tokens = 1000,
        keep_recent_tokens = 20,
    },
})
Chat.open()

Ui.set_prompt_text('new question')
Chat.send()

Test.truthy(Test.wait_for(function()
    return #requests >= 2
end), 'automatic compaction sends a summary request and the normal request')
Test.eq(#requests, 2, 'automatic compaction sends exactly one summary request')
Test.eq(requests[1].tools, nil, 'the automatic summary request does not send tools')
Test.eq(requests[1].config.stream, false, 'the automatic summary request is not streamed')
Test.eq(requests[2].config.stream, true, 'the normal chat request keeps streaming')

local injected = false
for _, message in ipairs(requests[2].messages) do
    if message.role == 'system'
        and type(message.content) == 'string'
        and message.content:find('FAKE SUMMARY', 1, true) then
        injected = true
    end
end
Test.truthy(injected, 'the summary is injected into the normal request')

local auto_saved = read_session(auto_path)
Test.eq(auto_saved.messages[1].content, 'original task', 'the original task survives automatic compaction')
Test.eq(auto_saved.messages[#auto_saved.messages].content, 'fake reply', 'the reply is stored after compaction')

-- Manual compaction: switch to a different long session and run the command
-- without sending a message.
local manual_path = write_session('manual-session', os.time() + 100, {
    { role = 'user', content = 'manual task' },
    { role = 'assistant', content = string.rep('manual work ', 200) },
    { role = 'user', content = 'manual latest question' },
})

Chat.setup({
    sessions_dir = dir,
    continue_last_session = true,
    compaction = {
        enabled = true,
        auto = false,
        threshold = 0.9,
        max_context_tokens = 128000,
        keep_recent_tokens = 20,
    },
})

local original_select = vim.ui.select
vim.ui.select = function(items, _, callback)
    callback(items[1])
end
Chat.select_session()
vim.ui.select = original_select

Test.truthy(Chat.compact ~= nil, 'the compaction command is available')
requests = {}
Chat.compact()

Test.truthy(Test.wait_for(function()
    return read_session(manual_path).compaction ~= nil
end), 'manual compaction stores a summary')

local manual_saved = read_session(manual_path)
Test.eq(#requests, 1, 'manual compaction sends one summary request')
Test.eq(requests[1].config.stream, false, 'manual compaction does not stream')
Test.eq(requests[1].tools, nil, 'manual compaction does not send tools')
Test.eq(manual_saved.compaction.summary, 'FAKE SUMMARY', 'manual summary is persisted')
Test.eq(manual_saved.messages[1].content, 'manual task', 'the original task survives manual compaction')

Chat.close()
vim.fn.delete(dir, 'rf')
