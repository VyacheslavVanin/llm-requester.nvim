local History = require('llm-requester.processing.history')

local Test = _G.Test

local base = vim.fn.tempname() .. '-llm-requester-processing-history'
local path = base .. '/history.json'

local function read_history(target)
    local instance = History.new({ path = target or path, limit = 10 })
    local prompts, err = instance:load()
    return instance, prompts, err
end

do
    local instance, prompts, err = read_history()
    Test.eq(#prompts, 0, 'missing history file yields an empty history')
    Test.eq(err, nil, 'missing history file is not an error')

    Test.truthy(instance:add('  first prompt  '), 'prompt is saved')
    Test.eq(instance:entries(), { 'first prompt' }, 'prompt is trimmed')
    Test.eq(vim.fn.filereadable(path), 1, 'history file is created')
    Test.eq(vim.fn.filereadable(path .. '.tmp'), 0, 'temporary file is removed')

    instance:add('second prompt')
    Test.eq(instance:entries(), { 'second prompt', 'first prompt' }, 'new prompts are added to the front')

    instance:add('first prompt')
    Test.eq(instance:entries(), { 'first prompt', 'second prompt' }, 'duplicates are moved to the front')
end

do
    local limited = History.new({ path = base .. '/limited.json', limit = 2 })
    limited:load()
    limited:add('one')
    limited:add('two')
    limited:add('three')

    Test.eq(limited:entries(), { 'three', 'two' }, 'history is trimmed to the configured limit')
end

do
    local instance, prompts = read_history()
    Test.eq(#prompts, 2, 'history survives a reload')
    Test.eq(prompts[1], 'first prompt', 'newest prompt is loaded first')

    local again = History.new({ path = path, limit = 10 })
    again:load()
    Test.eq(again:add('   '), true, 'empty prompts are ignored without an error')
    Test.eq(again:entries(), { 'first prompt', 'second prompt' }, 'empty prompts are not stored')
end

do
    vim.fn.writefile({ 'not a json document' }, base .. '/broken.json')

    local instance = History.new({ path = base .. '/broken.json', limit = 10 })
    local prompts, err = instance:load()
    Test.eq(#prompts, 0, 'broken history is treated as empty')
    Test.truthy(err and err:find('invalid', 1, true), 'broken history reports an error')
end

do
    vim.fn.writefile({ vim.json.encode({ 'old', 'duplicate', 'old' }) }, base .. '/plain.json')

    local instance = History.new({ path = base .. '/plain.json', limit = 10 })
    local prompts = instance:load()
    Test.eq(prompts, { 'old', 'duplicate' }, 'plain arrays are accepted and deduplicated')
end

do
    Test.eq(History.cycle_index(0, 3, 'older'), 1, 'the first older step shows the newest prompt')
    Test.eq(History.cycle_index(1, 3, 'older'), 2, 'older steps move through the history')
    Test.eq(History.cycle_index(3, 3, 'older'), 1, 'older steps wrap from the oldest to the newest')

    Test.eq(History.cycle_index(0, 3, 'newer'), 3, 'the first newer step from the draft shows the oldest prompt')
    Test.eq(History.cycle_index(3, 3, 'newer'), 2, 'newer steps move towards the newest prompt')
    Test.eq(History.cycle_index(1, 3, 'newer'), 0, 'newer steps restore the draft after the newest prompt')

    Test.eq(History.cycle_index(0, 0, 'older'), 0, 'empty history keeps the draft')
    Test.eq(History.cycle_index(0, 0, 'newer'), 0, 'empty history keeps the draft in both directions')
end

vim.fn.delete(base, 'rf')
