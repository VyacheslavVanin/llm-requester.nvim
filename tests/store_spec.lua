local Store = require('llm-requester.chat.store')

local Test = _G.Test

local dir = vim.fn.tempname() .. '-llm-requester-sessions'
local store = Store.new(dir)

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

vim.fn.delete(dir, 'rf')
