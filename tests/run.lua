package.path = package.path .. ';./?.lua;./?/init.lua'

local Test = dofile('tests/helpers.lua')
_G.Test = Test

local specs = {
    'tests/sse_spec.lua',
    'tests/session_spec.lua',
    'tests/store_spec.lua',
    'tests/utils_spec.lua',
}

for _, spec in ipairs(specs) do
    local ok, err = pcall(dofile, spec)
    if not ok then
        Test.fail(spec .. ': ' .. tostring(err))
    end
end

Test.report()
