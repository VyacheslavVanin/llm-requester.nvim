local api = vim.api
local Completion = require('llm-requester.completion.completion')

local Test = _G.Test

local original_show = Completion.show
local original_pumvisible = vim.fn.pumvisible

local shown = 0
Completion.show = function()
    shown = shown + 1
end

local function trigger_callback()
    for _, mapping in ipairs(api.nvim_get_keymap('i')) do
        if mapping.lhs == '<C-Tab>' and mapping.callback then
            return mapping.callback
        end
    end
    return nil
end

Completion.setup({ keys = { trigger = '<C-Tab>' } })

local callback = trigger_callback()
Test.truthy(callback, 'the completion trigger is installed as a global insert-mode mapping')

-- A temporary buffer-local mapping from another plugin (llama.vim, YCM)
-- takes priority while it exists and exposes the global trigger again after
-- being removed.
api.nvim_buf_set_keymap(0, 'i', '<C-Tab>', '', {
    noremap = true,
    callback = function() end,
})
Test.eq(
    vim.fn.maparg('<C-Tab>', 'i', false, true).buffer,
    1,
    'a buffer-local mapping overrides the global trigger'
)
api.nvim_buf_del_keymap(0, 'i', '<C-Tab>')
Test.eq(
    vim.fn.maparg('<C-Tab>', 'i', false, true).buffer,
    0,
    'the global trigger is exposed again after the buffer-local mapping is removed'
)

-- No popup: the LLM completion is scheduled.
vim.fn.pumvisible = function()
    return 0
end
Test.eq(callback(), '', 'the trigger returns an empty string outside a popup')
Test.truthy(Test.wait_for(function()
    return shown == 1
end), 'the trigger schedules the LLM completion')

-- Popup visible: the trigger does not start the LLM completion and keeps the
-- standard previous-item navigation.
vim.fn.pumvisible = function()
    return 1
end
Test.eq(
    callback(),
    api.nvim_replace_termcodes('<C-p>', true, false, true),
    'the trigger returns popup navigation while the popup is visible'
)
vim.wait(50, function()
    return false
end)
Test.eq(shown, 1, 'the trigger does not start the LLM completion while the popup is visible')

Completion.show = original_show
vim.fn.pumvisible = original_pumvisible
pcall(api.nvim_del_user_command, 'LLMRequesterCompletion')
pcall(api.nvim_del_augroup_by_name, 'LLMRequesterCompletion')
pcall(api.nvim_del_keymap, 'i', '<C-Tab>')
