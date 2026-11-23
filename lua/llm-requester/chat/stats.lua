-- Generation speed statistics for one assistant reply.
--
-- The tracker is intentionally clock-injectable: Chat feeds streamed chunks
-- and provider usage into it, while tests can use a fake clock. Live estimates
-- use characters per second; once the provider reports completion tokens the
-- value becomes tokens per second.

local Stats = {}
Stats.__index = Stats

local function default_clock()
    local uv = vim.uv or vim.loop
    return uv.now()
end

function Stats.new(options)
    options = options or {}

    return setmetatable({
        clock = options.clock or default_clock,
        interval = tonumber(options.interval) or 250,
        started_at = 0,
        first_chunk_at = nil,
        chars = 0,
        last_publish = 0,
        last = nil,
    }, Stats)
end

function Stats:start()
    self.started_at = self.clock()
    self.first_chunk_at = nil
    self.chars = 0
    self.last_publish = 0
    self.last = nil
end

function Stats:_elapsed(now)
    local start = self.first_chunk_at or self.started_at
    return math.max(0.001, (now - start) / 1000)
end

function Stats:_chars_snapshot(now, live)
    if self.chars <= 0 then
        return nil
    end

    local seconds = self:_elapsed(now)
    return {
        live = live,
        chars = self.chars,
        seconds = seconds,
        chars_per_second = self.chars / seconds,
    }
end

---Records a streamed chunk. Returns a throttled live snapshot or nil.
function Stats:on_delta(chunk)
    if type(chunk) ~= 'string' or chunk == '' then
        return nil
    end

    local now = self.clock()
    self.chars = self.chars + #chunk

    if not self.first_chunk_at then
        self.first_chunk_at = now
        self.last_publish = now
        return nil
    end

    if now - self.first_chunk_at < self.interval then
        return nil
    end
    if now - self.last_publish < self.interval then
        return nil
    end

    self.last_publish = now
    return self:_chars_snapshot(now, true)
end

---Computes the final speed for the round. Prefers provider output tokens.
function Stats:on_usage(usage)
    local now = self.clock()
    local output = tonumber(usage and usage.output) or 0

    if output > 0 then
        local seconds = self:_elapsed(now)
        self.last = {
            live = false,
            output = output,
            seconds = seconds,
            tokens_per_second = output / seconds,
        }
        return self.last
    end

    return self:finish()
end

---Returns the best known snapshot for the finished round.
function Stats:finish()
    if self.last then
        return self.last
    end

    local snapshot = self:_chars_snapshot(self.clock(), false)
    if snapshot then
        snapshot.approx = true
    end
    self.last = snapshot
    return snapshot
end

---Formats a snapshot for the winbar.
function Stats.format(snapshot)
    if type(snapshot) ~= 'table' then
        return ''
    end

    if snapshot.tokens_per_second then
        return string.format('%.1f tok/s', snapshot.tokens_per_second)
    end

    if snapshot.chars_per_second then
        return string.format('~%.0f ch/s', snapshot.chars_per_second)
    end

    return ''
end

return Stats
