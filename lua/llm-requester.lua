local api = vim.api
local fn = vim.fn

local Completion = require('llm-requester.completion.completion')
local Processing = require('llm-requester.processing.processing')
local Tools = require("llm-requester.tools")

local M = {}

local config = {
    chat = {
        api_type = 'openai', -- 'openai' only

        openai_url = 'https://api.openai.com/v1/chat/completions',
        api_key_file = '', -- Path to file containing the API key
        openai_model = 'gpt-4o-mini',

        split_ratio = 0.5,
        prompt_split_ratio = 0.2, -- parameter to control dimensions of prompt and response windows
        context_size = 16384, -- maximum context size in tokens
        prompt = 'Please review, improve, and refactor the following code. Provide your suggestions in markdown format with explanations:\n\n',
        open_prompt_window_key = '<leader>ai',
        request_keys = '<leader>r',
        close_keys = '<leader>q',
        clear_keys = '<leader>cc', -- reset chat
        stream = false,
        max_rps = 100,  -- limit llm request rate
        no_verify_ssl = false,
        timeout = nil,
    },
    completion = {
        openai_model = 'gpt-4o-mini',
        api_key_file = '', -- Path to file containing the API key
        keys = {
            trigger = '<C-Tab>',
            confirm = '<Tab>',
        },
        context_lines = 3,
        context_size = 16384, -- maximum context size in tokens
        menu_height = 10,
        menu_width = 50,
        menu_hl = 'NormalFloat',
        menu_border = 'rounded',
    }
}

local ns_id = api.nvim_create_namespace('llm_requester')

function M.setup(user_config)
    config = vim.tbl_extend('force', config, user_config or {})

    -- Ensure completion config includes api_key_file if not present
    local completion_config = vim.deepcopy(config.completion)
    if user_config and user_config.completion then
        completion_config = vim.tbl_extend('force', completion_config, user_config.completion)
    end

    Completion.setup(vim.tbl_extend('force', {url = config.url}, completion_config))

    -- Setup processing module
    local processing_config = vim.deepcopy(config.completion) -- Use similar config as completion
    if user_config and user_config.processing then
        processing_config = vim.tbl_extend('force', processing_config, user_config.processing)
    end
    Processing.setup(processing_config)

    local chat_config = user_config.chat
    if not chat_config and not user_config.completion and next(user_config) ~= nil then
        vim.notify('Options for chat moved to "chat" section of config. See README')
        -- For backward compatibility
        local d = Tools.default_config
        chat_config = vim.deepcopy(d)
        chat_config.openai_url = config.url or d.openai_url
        chat_config.openai_model = config.model or d.openai_model
        chat_config.split_ratio = config.split_ratio or d.split_ratio
        chat_config.prompt_split_ratio = config.prompt_split_ratio or d.prompt_split_ratio
        chat_config.prompt = config.prompt or d.prompt
        chat_config.open_prompt_window_key = config.open_prompt_window_key or d.open_prompt_window_key
        chat_config.request_keys = config.request_keys or d.request_keys
        chat_config.close_keys = config.close_keys or d.close_keys
        chat_config.stream = config.stream or d.stream
    end
    Tools.setup(vim.tbl_extend('force', config.chat, chat_config or {}))
end

return M
