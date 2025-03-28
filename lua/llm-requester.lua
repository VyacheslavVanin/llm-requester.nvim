local api = vim.api
local fn = vim.fn

local Completion = require('llm-requester.completion')
local Chat = require('llm-requester.chat') -- Require the chat module

local M = {}

local config = {
    api_type = 'ollama', -- 'ollama' or 'openai'
    model = 'llama2',
    url = 'http://localhost:11434/api/chat',
    openai_url = 'https://openrouter.ai/api/v1/chat/completions',
    openai_api_key = '', -- Set your OpenAI API key here or via setup()
    split_ratio = 0.6,
    prompt_split_ratio = 0.2, -- parameter to control dimensions of prompt and response windows
    prompt = 'Please review, improve, and refactor the following code. Provide your suggestions in markdown format with explanations:\n\n',
    open_prompt_window_key = '<leader>ai',
    request_keys = '<leader>r',
    close_keys = '<leader>q',
    stream = false,
    completion = {
        model = 'llama2',
        keys = {
            trigger = '<C-Tab>',
            confirm = '<Tab>',
        },
        context_lines = 3,
        menu_height = 10,
        menu_width = 50,
        menu_hl = 'NormalFloat',
        menu_border = 'rounded',
    }
}

local ns_id = api.nvim_create_namespace('llm_requester')

function M.setup(user_config)
    config = vim.tbl_extend('force', config, user_config or {})
    Completion.setup(vim.tbl_extend('force', {url = config.url}, config.completion))
    Chat.setup(config) -- Chat still uses full config
end

vim.api.nvim_create_user_command('LLMRequester', Chat.open_code_window, { range = true })
vim.keymap.set('v', config.open_prompt_window_key, Chat.open_code_window, { desc = 'Open LLMRequester window' })
vim.keymap.set('n', config.open_prompt_window_key, Chat.open_code_window, { desc = 'Open LLMRequester window' })

return M
