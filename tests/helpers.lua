local Test = {
    failures = {},
    assertions = 0,
}

local function record_failure(message)
    table.insert(Test.failures, message)
end

function Test.eq(actual, expected, message)
    Test.assertions = Test.assertions + 1
    if not vim.deep_equal(actual, expected) then
        record_failure(string.format(
            '%s\nexpected: %s\nactual:   %s',
            message or 'values differ',
            vim.inspect(expected),
            vim.inspect(actual)
        ))
    end
end

function Test.truthy(value, message)
    Test.assertions = Test.assertions + 1
    if not value then
        record_failure(message or 'expected a truthy value')
    end
end

function Test.falsy(value, message)
    Test.assertions = Test.assertions + 1
    if value then
        record_failure(message or 'expected a falsy value')
    end
end

function Test.fail(message)
    record_failure(message)
end

function Test.report()
    if #Test.failures > 0 then
        print(string.format('FAILED: %d failure(s), %d assertion(s)', #Test.failures, Test.assertions))
        for _, failure in ipairs(Test.failures) do
            print(failure)
        end
        vim.cmd('cq')
        return
    end

    print(string.format('OK: %d assertion(s)', Test.assertions))
    vim.cmd('cq 0')
end

return Test
