local api = vim.api
local fn = vim.fn

local Completion = require('llm-requester.completion')
local Chat = require('llm-requester.chat') -- Require the chat module

local M = {}

local config = {
    chat = {
        api_type = 'ollama', -- 'ollama' or 'openai'

        ollama_url = 'http://localhost:11434/api/chat',
        ollama_model = 'llama2',

        openai_url = 'https://api.openai.com/v1/chat/completions',
        openai_api_key = '', -- Set your OpenAI API key here or via setup()
        openai_model = 'gpt-4o-mini',

        split_ratio = 0.5,
        prompt_split_ratio = 0.2, -- parameter to control dimensions of prompt and response windows
        prompt = 'Please review, improve, and refactor the following code. Provide your suggestions in markdown format with explanations:\n\n',
        open_prompt_window_key = '<leader>ai',
        request_keys = '<leader>r',
        close_keys = '<leader>q',
        stream = false,
    },
    completion = {
        ollama_model = 'llama2',
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

    local chat_config = user_config.chat
    if not chat_config and not user_config.completion and next(user_config) ~= nil then
        vim.notify('Options for chat moved to "chat" section of config. See README')
        -- For backward compatibility
        local d = Chat.default_config
        chat_config = vim.deepcopy(d)
        chat_config.ollama_url = config.url or d.ollama_url
        chat_config.ollama_model = config.model or d.ollama_mode
        chat_config.split_ratio = config.split_ratio or d.split_ratio
        chat_config.prompt_split_ratio = config.prompt_split_ratio or d.prompt_split_ratio
        chat_config.prompt = config.prompt or d.prompt
        chat_config.open_prompt_window_key = config.open_prompt_window_key or d.open_prompt_window_key
        chat_config.request_keys = config.request_keys or d.request_keys
        chat_config.close_keys = config.close_keys or d.close_keys
        chat_config.stream = config.stream or d.stream
    end
    Chat.setup(vim.tbl_extend('force', config.chat, chat_config or {}))
end

vim.api.nvim_create_user_command('LLMRequester', Chat.open_code_window, { range = true })

return M
