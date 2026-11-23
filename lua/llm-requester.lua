local M = {}

local Completion = require('llm-requester.completion.completion')
local Processing = require('llm-requester.processing.processing')
local Chat = require('llm-requester.chat')

function M.setup(user_config)
    user_config = user_config or {}

    Chat.setup(user_config.chat or {})
    Completion.setup(user_config.completion or {})

    local processing_config = vim.tbl_deep_extend(
        'force',
        vim.deepcopy(user_config.completion or {}),
        user_config.processing or {}
    )
    Processing.setup(processing_config)
end

return M
