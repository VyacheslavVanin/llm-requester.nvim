package.path = package.path .. ';./?.lua;./?/init.lua'

local Test = dofile('tests/helpers.lua')
_G.Test = Test

local specs = {
    'tests/sse_spec.lua',
    'tests/session_spec.lua',
    'tests/store_spec.lua',
    'tests/utils_spec.lua',
    'tests/paths_spec.lua',
    'tests/permissions_spec.lua',
    'tests/tools_spec.lua',
    'tests/protocol_spec.lua',
    'tests/compaction_spec.lua',
    'tests/completion_spec.lua',
    'tests/stats_spec.lua',
    'tests/processing_history_spec.lua',
    'tests/processing_cycle_spec.lua',
    'tests/ui_spec.lua',
    'tests/agent_spec.lua',
    'tests/chat_compaction_spec.lua',
}

for _, spec in ipairs(specs) do
    local ok, err = pcall(dofile, spec)
    if not ok then
        Test.fail(spec .. ': ' .. tostring(err))
    end
end

Test.report()
