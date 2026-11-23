local Utils = require('llm-requester.utils')

local Test = _G.Test

Test.eq(
    Utils.completions_url('https://api.openai.com/v1'),
    'https://api.openai.com/v1/chat/completions',
    'base URL gets the completions path'
)

Test.eq(
    Utils.completions_url('https://api.openai.com/v1/'),
    'https://api.openai.com/v1/chat/completions',
    'trailing slash is removed'
)

Test.eq(
    Utils.completions_url('https://api.openai.com/v1/chat/completions'),
    'https://api.openai.com/v1/chat/completions',
    'complete endpoint is not appended twice'
)

Test.eq(Utils.completions_url(''), '', 'empty URL stays empty')
