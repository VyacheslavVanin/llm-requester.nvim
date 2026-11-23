local Store = require('llm-requester.chat.store')

local Test = _G.Test

local dir = vim.fn.tempname() .. '-llm-requester-sessions'
local store = Store.new(dir)
local second_id = nil

do
    local first = store:new_session('/project/a', 'model-a')
    first:add_user('hello')
    first:add_assistant('hi')

    local ok, err = store:save(first)
    Test.truthy(ok, 'session save succeeds: ' .. tostring(err))
    Test.eq(vim.fn.filereadable(store:path(first.id)), 1, 'session file exists')
    Test.eq(vim.fn.filereadable(store:path(first.id) .. '.tmp'), 0, 'temporary file is removed')

    local loaded = store:load(first.id)
    Test.truthy(loaded, 'session load succeeds')
    Test.eq(loaded.id, first.id, 'loaded session id')
    Test.eq(loaded.cwd, '/project/a', 'loaded session cwd')
    Test.eq(#loaded.messages, 2, 'loaded message count')

    vim.uv.sleep(1100)

    local second = store:new_session('/project/b', 'model-b')
    second:add_user('second')
    Test.truthy((store:save(second)), 'second session save succeeds')
    second_id = second.id

    local entries = store:list()
    Test.eq(#entries, 2, 'both sessions are listed')
    Test.eq(entries[1].id, second.id, 'sessions are sorted by update time')

    Test.eq(store:latest('/project/a').id, first.id, 'latest session for cwd')
    Test.eq(store:latest('/missing'), nil, 'no latest session for unknown cwd')
end

do
    vim.fn.writefile({ 'not a json document' }, dir .. '/broken.json')

    local entries = store:list()
    Test.eq(#entries, 2, 'broken session files are skipped')
    Test.eq(store:load('missing'), nil, 'missing session returns nil')
    Test.eq(store:load('broken'), nil, 'broken session returns nil')
end

do
    local agent = store:new_session('/project/a', 'model-a', 'agent')
    agent:add_user('inspect the repository')
    Test.truthy((store:save(agent)), 'agent session save succeeds')
    Test.eq(agent.mode, 'agent', 'agent session mode')
    Test.eq(agent.root, '/project/a', 'agent session root')

    Test.eq(store:latest('/project/a', 'agent').id, agent.id, 'agent session is found by mode')
    Test.eq(store:latest('/project/a', 'chat').mode, 'chat', 'chat lookup ignores agent sessions')
    Test.eq(store:latest('/project/a', 'agent').root, '/project/a', 'agent root survives storage')

    store:delete(agent.id)
end

do
    Test.eq(store:delete(second_id), true, 'session file is deleted')
    Test.eq(vim.fn.filereadable(store:path(second_id)), 0, 'deleted session file is gone')
    Test.eq(store:delete('missing'), true, 'deleting a missing session is a no-op')
end

vim.fn.delete(dir, 'rf')
