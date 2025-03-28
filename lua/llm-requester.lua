local api = vim.api
local fn = vim.fn

local Completion = require('llm-requester.completion')
local Chat = require('llm-requester.chat') -- Require the chat module

local M = {}

local config = {
    model = 'llama2',
    completion_model = 'llama2', -- Added separate model for completion
    url = 'http://localhost:11434/api/chat',
    split_ratio = 0.6,
    prompt_split_ratio = 0.2, -- parameter to control dimensions of prompt and response windows
    prompt = 'Please review, improve, and refactor the following code. Provide your suggestions in markdown format with explanations:\n\n',
    open_prompt_window_key = '<leader>ai',
    request_keys = '<leader>r',
    close_keys = '<leader>q',
    stream = false,
    completion_keys = {
        trigger = '<C-Tab>',
        confirm = '<Tab>',
    },
    completion_context_lines = 3, -- number of lines before/after cursor to use as context
    completion_menu_height = 10,
    completion_menu_width = 50,
    completion_menu_hl = 'NormalFloat',
    completion_menu_border = 'rounded',
}

local ns_id = api.nvim_create_namespace('llm_requester')

function M.setup(user_config)
    config = vim.tbl_extend('force', config, user_config or {})
    Completion.setup(config) -- Call setup from the completion module
    Chat.setup(config) -- Call setup from the chat module
end

vim.api.nvim_create_user_command('LLMRequester', Chat.open_code_window, { range = true })
vim.keymap.set('v', config.open_prompt_window_key, Chat.open_code_window, { desc = 'Open LLMRequester window' })
vim.keymap.set('n', config.open_prompt_window_key, Chat.open_code_window, { desc = 'Open LLMRequester window' })

return M
