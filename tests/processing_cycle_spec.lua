local api = vim.api
local Processing = require('llm-requester.processing.processing')
local History = require('llm-requester.processing.history')

local Test = _G.Test

local base = vim.fn.tempname() .. '-llm-requester-processing-cycle'
local path = base .. '/history.json'

local history = History.new({ path = path, limit = 10 })
history:load()
history:add('prompt one')
history:add('prompt two')
history:add('prompt three')

Processing.setup({
    history_file = path,
    history_size = 10,
})

local source_buf = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(source_buf)
api.nvim_buf_set_lines(source_buf, 0, -1, false, { 'selected line one', 'selected line two' })
vim.fn.setpos("'<", { 0, 1, 1, 0 })
vim.fn.setpos("'>", { 0, 2, 1, 0 })

Processing.start_process({ args = 'draft prompt' })

local prompt_buf = api.nvim_get_current_buf()

local function prompt_lines()
    return api.nvim_buf_get_lines(prompt_buf, 0, -1, false)
end

Test.eq(prompt_lines(), { 'draft prompt' }, 'the initial prompt is kept as the draft')
Test.eq(vim.fn.exists(':LLMRequesterProcessHistoryPrev'), 2, 'history previous command is registered')
Test.eq(vim.fn.exists(':LLMRequesterProcessHistoryNext'), 2, 'history next command is registered')

Processing.history_prev()
Test.eq(prompt_lines(), { 'prompt three' }, 'first previous step shows the newest prompt')

Processing.history_prev()
Test.eq(prompt_lines(), { 'prompt two' }, 'previous steps move to older prompts')

Processing.history_prev()
Test.eq(prompt_lines(), { 'prompt one' }, 'the oldest prompt is reachable')

Processing.history_prev()
Test.eq(prompt_lines(), { 'prompt three' }, 'previous steps wrap to the newest prompt')

Processing.history_next()
Test.eq(prompt_lines(), { 'draft prompt' }, 'next after the newest prompt restores the draft')

Processing.history_next()
Test.eq(prompt_lines(), { 'prompt one' }, 'next from the draft shows the oldest prompt')

local has_prev = false
local has_next = false
for _, mapping in ipairs(api.nvim_buf_get_keymap(prompt_buf, 'i')) do
    local lhs = (mapping.lhs or ''):lower()
    if lhs == '<c-p>' then
        has_prev = true
    elseif lhs == '<c-n>' then
        has_next = true
    end
end
Test.truthy(has_prev, 'insert-mode previous mapping is installed')
Test.truthy(has_next, 'insert-mode next mapping is installed')

Processing.cancel()
api.nvim_buf_delete(source_buf, { force = true })
vim.fn.delete(base, 'rf')
