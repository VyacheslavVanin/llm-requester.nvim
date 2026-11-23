local Stats = require('llm-requester.chat.stats')

local Test = _G.Test

local now = 1000

local function new_stats()
    return Stats.new({
        clock = function()
            return now
        end,
        interval = 250,
    })
end

do
    local stats = new_stats()
    stats:start()

    Test.eq(stats:on_delta('abcd'), nil, 'the first chunk starts the timer')
    now = 1200
    Test.eq(stats:on_delta('efgh'), nil, 'live updates are throttled')
    now = 1250
    local live = stats:on_delta('ijkl')
    Test.truthy(live, 'a live snapshot is produced after the interval')
    Test.truthy(live.live, 'live snapshot is marked as live')
    Test.eq(live.chars, 12, 'all streamed characters are counted')
    Test.eq(Stats.format(live), '~48 ch/s', 'live speed is formatted as characters per second')

    now = 2000
    local final = stats:on_usage({ output = 10 })
    Test.falsy(final.live, 'usage snapshot is final')
    Test.eq(final.output, 10, 'output token count is kept')
    Test.eq(Stats.format(final), '10.0 tok/s', 'final speed is formatted as tokens per second')
end

do
    now = 5000
    local stats = new_stats()
    stats:start()

    stats:on_delta('abcdefgh')
    now = 6000
    stats:on_delta('ijklmnop')

    local final = stats:finish()
    Test.truthy(final, 'finish produces a fallback snapshot')
    Test.truthy(final.approx, 'character fallback is marked approximate')
    Test.eq(Stats.format(final), '~16 ch/s', 'fallback speed is formatted')
    Test.eq(stats:finish(), final, 'finish is stable after the first call')
end

do
    now = 9000
    local stats = new_stats()
    stats:start()

    Test.eq(stats:finish(), nil, 'no output produces no speed')
    Test.eq(Stats.format(nil), '', 'missing snapshot formats to an empty string')
    Test.eq(Stats.format({}), '', 'empty snapshot formats to an empty string')

    stats:on_delta('abc')
    now = 9500
    Test.truthy(stats:on_usage({ output = 0 }), 'zero usage falls back to characters')
end

do
    now = 12000
    local stats = new_stats()
    stats:start()
    stats:on_delta('abc')
    now = 12250
    stats:on_usage({ output = 5 })

    stats:start()
    Test.eq(stats:finish(), nil, 'start resets the previous result')
end
