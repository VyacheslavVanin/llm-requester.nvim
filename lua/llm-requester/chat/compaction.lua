-- Context compaction for chats and agent sessions.
--
-- The conversation is split into a preserved tail (kept verbatim), the
-- original user task (always kept verbatim) and a prefix that is replaced by
-- an LLM-generated structured summary. The summary lives on the session, so
-- the persisted message list stays valid for providers: tool calls and their
-- results are never split across the compaction boundary.
--
-- Compaction is deterministic in what it keeps (see `plan`) and only uses the
-- model to summarize the dropped prefix. When the prefix does not fit into a
-- single request it is summarized sequentially, merging each chunk into the
-- running summary.

local Compaction = {}

local CHARS_PER_TOKEN = 4
local SUMMARY_PROMPT_RESERVE_TOKENS = 2000
local MIN_CHUNK_TOKENS = 1000
local TOOL_ARGUMENT_PREVIEW_CHARS = 1200

local DEFAULT_SYSTEM_PROMPT = [[
You maintain the working memory of a long coding conversation.
You will receive an existing summary and a new fragment of the conversation.
Merge them into a single updated summary.

The user's original task is preserved verbatim outside the summary, and the
most recent messages are kept verbatim. Your summary replaces everything else,
so it must not lose information needed to continue the work.

Always keep:
1. The user's goal and every explicit acceptance criterion or constraint.
2. The solution plan as numbered stages, each marked done, current or pending.
3. Every distinct user remark, correction, preference and answer. Collapse
   exact repetitions, but never drop a unique detail or requirement.
4. What has already been done: files read or changed, commands run, outcomes.
5. The last agent action and the immediate next step.
6. Key paths, identifiers, decisions and unresolved questions.

Do not invent facts. Do not paste tool output or file contents verbatim; keep
only conclusions and essential details. Be concise, but never omit an item
from the list above.

Reply with the summary only, using these Markdown sections:
## Goal
## Plan and progress
## User remarks and answers
## Work completed
## Last action and next step
## Key details
## Open questions
]]

local DEFAULT_PROMPT = [[
Original task (kept verbatim in the conversation):
{task}

Previous summary:
{summary}

Conversation fragment to merge into the summary:
{fragment}
]]

local DEFAULTS = {
    enabled = true,
    auto = true,
    threshold = 0.9,
    max_context_tokens = 128000,
    keep_recent_tokens = 8000,
    max_summary_tokens = 1500,
    max_message_chars = 4000,
    model = nil,
    system_prompt = DEFAULT_SYSTEM_PROMPT,
    prompt = DEFAULT_PROMPT,
}

-- Single source of truth for compaction defaults. Callers may read (and
-- deepcopy) this table, but must not mutate it.
Compaction.defaults = DEFAULTS

---Resolves the effective compaction options for a chat config.
function Compaction.options(config)
    local value = type(config) == 'table' and type(config.compaction) == 'table' and config.compaction or {}
    local options = vim.tbl_deep_extend('force', vim.deepcopy(DEFAULTS), value)

    options.threshold = math.max(0.1, math.min(1, tonumber(options.threshold) or DEFAULTS.threshold))
    options.max_context_tokens = math.max(
        100,
        math.floor(tonumber(options.max_context_tokens) or DEFAULTS.max_context_tokens)
    )
    options.keep_recent_tokens = math.max(
        0,
        math.floor(tonumber(options.keep_recent_tokens) or DEFAULTS.keep_recent_tokens)
    )
    options.max_summary_tokens = math.max(
        100,
        math.floor(tonumber(options.max_summary_tokens) or DEFAULTS.max_summary_tokens)
    )
    options.max_message_chars = math.max(
        200,
        math.floor(tonumber(options.max_message_chars) or DEFAULTS.max_message_chars)
    )

    if type(options.model) ~= 'string' or options.model == '' then
        options.model = config and config.openai_model or ''
    end
    if type(options.system_prompt) ~= 'string' or options.system_prompt == '' then
        options.system_prompt = DEFAULT_SYSTEM_PROMPT
    end
    if type(options.prompt) ~= 'string' or options.prompt == '' then
        options.prompt = DEFAULT_PROMPT
    end

    return options
end

---Returns whether compaction is enabled at all (manual or automatic).
function Compaction.is_enabled(config)
    return Compaction.options(config).enabled ~= false
end

---Returns whether automatic compaction is allowed.
function Compaction.is_auto_enabled(config)
    local opts = Compaction.options(config)
    return opts.enabled ~= false and opts.auto ~= false
end

local function trim(text)
    return (tostring(text or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

---Rough token estimate. Providers differ, but the threshold leaves a margin.
function Compaction.estimate_text_tokens(text)
    if type(text) ~= 'string' or text == '' then
        return 0
    end
    return math.ceil(#text / CHARS_PER_TOKEN)
end

local function estimate_message_tokens(message)
    if type(message) ~= 'table' then
        return 0
    end

    local total = 4
    if type(message.content) == 'string' then
        total = total + Compaction.estimate_text_tokens(message.content)
    end

    for _, call in ipairs(message.tool_calls or {}) do
        if type(call) == 'table' and type(call['function']) == 'table' then
            local fn = call['function']
            total = total + 8
            total = total + Compaction.estimate_text_tokens(tostring(fn.name or ''))
            total = total + Compaction.estimate_text_tokens(tostring(fn.arguments or ''))
        end
    end

    return total
end

function Compaction.estimate_messages_tokens(messages)
    local total = 0
    for _, message in ipairs(messages or {}) do
        total = total + estimate_message_tokens(message)
    end
    return total
end

---Estimated number of tokens the next request will use.
---@param session table
---@param options table|nil { system_prompt, context, extra_tokens }
function Compaction.current_tokens(session, options)
    options = options or {}
    local messages = type(session) == 'table' and session.messages or {}

    local total = Compaction.estimate_text_tokens(options.system_prompt)
    total = total + Compaction.estimate_text_tokens(options.context)
    total = total + (tonumber(options.extra_tokens) or 0)
    total = total + Compaction.estimate_messages_tokens(messages)

    if type(session) == 'table'
        and session.compaction
        and type(session.compaction.summary) == 'string' then
        total = total + Compaction.estimate_text_tokens(session.compaction.summary)
    end

    local measured = tonumber(session and session.context_tokens)
    if measured then
        local count = tonumber(session.context_messages)
        if not count then
            count = #messages
        end
        count = math.max(0, math.min(count, #messages))

        local added = {}
        for index = count + 1, #messages do
            table.insert(added, messages[index])
        end

        -- Provider usage is authoritative for the measured part; the estimate
        -- covers messages appended since then.
        total = math.max(total, measured + Compaction.estimate_messages_tokens(added))
    end

    return math.max(0, math.floor(total))
end

---Returns whether the context reached the configured threshold.
---@return boolean reached
---@return number tokens
---@return number limit
function Compaction.should_compact(session, config, options)
    local opts = Compaction.options(config)
    local messages = type(session) == 'table' and session.messages or {}
    if #messages == 0 then
        return false, 0, 0
    end

    local tokens = Compaction.current_tokens(session, options)
    local limit = math.max(1, math.floor(opts.max_context_tokens * opts.threshold))
    return tokens >= limit, tokens, limit
end

local function find_task_index(messages)
    for index, message in ipairs(messages) do
        if message.role == 'user' then
            return index
        end
    end
    return nil
end

local function is_safe_tail_start(message)
    return message and (message.role == 'user' or message.role == 'assistant')
end

---Builds the deterministic compaction plan.
---
---Preserved verbatim:
---  * the first user message (the original task);
---  * the last `keep_recent_tokens` tokens, cut on a user/assistant boundary.
---
---Everything else is dropped from the message list and summarized. User
---messages inside the dropped part are summarized too, with an explicit
---instruction to keep every distinct remark while collapsing repetitions.
---
---@return table|nil plan { messages, dropped, dropped_count, task }
function Compaction.plan(session, config)
    local opts = Compaction.options(config)
    local messages = type(session) == 'table' and session.messages or {}
    if #messages == 0 then
        return nil
    end

    -- Collect a verbatim tail, newest first. Always include at least the last
    -- message even when it alone exceeds the budget.
    local tail_start = #messages + 1
    local accumulated = 0
    for index = #messages, 1, -1 do
        local tokens = estimate_message_tokens(messages[index])
        if tail_start <= #messages and accumulated + tokens > opts.keep_recent_tokens then
            break
        end
        accumulated = accumulated + tokens
        tail_start = index
    end

    -- Tool results cannot start a message list: move the boundary back to the
    -- assistant call they belong to.
    while tail_start > 1 and messages[tail_start] and messages[tail_start].role == 'tool' do
        tail_start = tail_start - 1
    end

    if tail_start > #messages or not is_safe_tail_start(messages[tail_start]) then
        tail_start = #messages + 1
    end

    local task_index = find_task_index(messages)

    local dropped = {}
    for index = 1, math.min(tail_start - 1, #messages) do
        if index ~= task_index then
            table.insert(dropped, messages[index])
        end
    end

    if #dropped == 0 then
        return nil
    end

    local tail = {}
    for index = tail_start, #messages do
        table.insert(tail, messages[index])
    end

    local compacted = {}
    if task_index and task_index < tail_start then
        table.insert(compacted, messages[task_index])
    end
    vim.list_extend(compacted, tail)

    return {
        messages = compacted,
        dropped = dropped,
        dropped_count = #dropped,
        task = task_index and messages[task_index] or nil,
    }
end

local function is_utf8_continuation(byte)
    return byte ~= nil and byte >= 0x80 and byte <= 0xBF
end

-- Moves a byte cut forward so the string is never split inside a UTF-8
-- character. Invalid input still makes progress because only continuation
-- bytes are skipped.
local function align_cut(text, cut)
    if cut <= 0 then
        return 0
    end
    if cut >= #text then
        return #text
    end
    while cut < #text and is_utf8_continuation(text:byte(cut + 1)) do
        cut = cut + 1
    end
    return cut
end

local function align_start(text, start)
    if start <= 1 then
        return 1
    end
    if start > #text then
        return #text + 1
    end
    while start <= #text and is_utf8_continuation(text:byte(start)) do
        start = start + 1
    end
    return start
end

local function truncate(text, limit)
    local value = tostring(text or '')
    if #value <= limit then
        return value
    end

    local head = align_cut(value, math.max(1, math.floor(limit * 0.7)))
    local tail = math.max(0, limit - head)
    local tail_start = tail > 0 and align_start(value, #value - tail + 1) or #value + 1
    return value:sub(1, head) .. '\n... [truncated] ...\n' .. value:sub(tail_start)
end

local function render_message(message, limit)
    local parts = {}

    if message.role == 'assistant' then
        table.insert(parts, '[assistant]')
        if type(message.content) == 'string' and message.content ~= '' then
            table.insert(parts, truncate(message.content, limit))
        end
        for _, call in ipairs(message.tool_calls or {}) do
            if type(call) == 'table' and type(call['function']) == 'table' then
                table.insert(parts, '[tool call] '
                    .. tostring(call['function'].name or '?')
                    .. ' '
                    .. truncate(
                        call['function'].arguments or '',
                        math.min(limit, TOOL_ARGUMENT_PREVIEW_CHARS)
                    ))
            end
        end
    elseif message.role == 'tool' then
        local name = type(message.name) == 'string' and message.name ~= '' and (' ' .. message.name) or ''
        table.insert(parts, '[tool result' .. name .. ']')
        table.insert(parts, truncate(message.content, limit))
    else
        table.insert(parts, '[' .. tostring(message.role or 'message') .. ']')
        table.insert(parts, truncate(message.content, limit))
    end

    return table.concat(parts, '\n')
end

local function make_chunks(blocks, budget_chars)
    local chunks = {}
    local buffer = {}
    local size = 0

    local function flush()
        if #buffer == 0 then
            return
        end
        table.insert(chunks, table.concat(buffer, '\n\n'))
        buffer = {}
        size = 0
    end

    for _, block in ipairs(blocks) do
        local remaining = block
        while #remaining > budget_chars do
            flush()
            local cut = align_cut(remaining, budget_chars)
            if cut <= 0 then
                cut = budget_chars
            end
            table.insert(chunks, remaining:sub(1, cut))
            remaining = remaining:sub(cut + 1)
        end

        if size + #remaining + 2 > budget_chars then
            flush()
        end
        table.insert(buffer, remaining)
        size = size + #remaining + 2
    end

    flush()
    return chunks
end

local function format_prompt(template, values)
    return (template:gsub('{(%w+)}', function(key)
        return values[key] or ''
    end))
end

local function make_job()
    local job = {
        cancelled = false,
        process = nil,
    }

    function job:kill()
        self.cancelled = true
        local process = self.process
        self.process = nil
        if process then
            pcall(function()
                process:kill(9)
            end)
        end
    end

    return job
end

local function build_summarizer_prompt(opts)
    return opts.system_prompt
        .. '\n\nTarget summary size: about '
        .. opts.max_summary_tokens
        .. ' tokens.'
end

local function build_summarizer_config(config, opts)
    return vim.tbl_deep_extend('force', {}, config or {}, {
        stream = false,
        openai_model = opts.model,
    })
end

---Prepares everything needed for the summarization requests: the rendered
---prefix, chunk boundaries, task text and the request config.
local function prepare_compaction(session, config, options, opts, plan)
    local blocks = {}
    for _, message in ipairs(plan.dropped) do
        table.insert(blocks, render_message(message, opts.max_message_chars))
    end

    local task_text = plan.task and plan.task.content or ''
    if trim(task_text) == '' then
        task_text = '(not available)'
    end

    local task_tokens = Compaction.estimate_text_tokens(task_text)
    local budget_tokens = math.max(
        MIN_CHUNK_TOKENS,
        opts.max_context_tokens
            - opts.max_summary_tokens
            - task_tokens
            - SUMMARY_PROMPT_RESERVE_TOKENS
    )

    local previous = session.compaction and session.compaction.summary or ''
    local summary = type(previous) == 'string' and trim(previous) or ''

    return {
        opts = opts,
        options = options,
        plan = plan,
        chunks = make_chunks(blocks, budget_tokens * CHARS_PER_TOKEN),
        task_text = task_text,
        summary = summary,
        before_tokens = Compaction.current_tokens(session, options),
        summarizer_prompt = build_summarizer_prompt(opts),
        request_config = build_summarizer_config(config, opts),
        -- Resolved lazily so tests and integrations can replace the transport
        -- module without depending on load order.
        request = options.request or require('llm-requester.chat.client').request,
    }
end

local function apply_compaction(session, prepared)
    local after_tokens = Compaction.estimate_messages_tokens(prepared.plan.messages)
        + Compaction.estimate_text_tokens(prepared.options.system_prompt)
        + Compaction.estimate_text_tokens(prepared.summary)
        + (tonumber(prepared.options.extra_tokens) or 0)

    local applied = session:apply_compaction(prepared.summary, prepared.plan.messages, {
        compacted_messages = prepared.plan.dropped_count,
        model = prepared.opts.model,
    })

    if not applied then
        return nil, 'failed to apply the compaction to the session'
    end

    return {
        summarized = prepared.plan.dropped_count,
        before_tokens = prepared.before_tokens,
        after_tokens = math.floor(after_tokens),
        chunks = #prepared.chunks,
    }
end

---Summarizes chunks sequentially, merging each response into the running
---summary, and applies the final summary to the session.
local function run_compaction(session, prepared, job, callback)
    local opts = prepared.opts
    local summary = prepared.summary
    local index = 0
    local completed = false

    local function finish(ok, result)
        if completed or job.cancelled then
            return
        end
        completed = true
        job.process = nil
        callback(ok, result)
    end

    local function step()
        if completed or job.cancelled then
            return
        end

        index = index + 1
        if index > #prepared.chunks then
            prepared.summary = summary
            local result, err = apply_compaction(session, prepared)
            finish(result ~= nil, result or err)
            return
        end

        local content = format_prompt(opts.prompt, {
            task = prepared.task_text,
            summary = summary ~= '' and summary or '(none)',
            fragment = prepared.chunks[index],
        })

        local called, process = pcall(prepared.request, {
            config = prepared.request_config,
            messages = {
                { role = 'system', content = prepared.summarizer_prompt },
                { role = 'user', content = content },
            },
            on_finish = function(text)
                if job.cancelled or completed then
                    return
                end
                job.process = nil

                local value = trim(text)
                if value == '' then
                    finish(false, 'the model returned an empty summary')
                    return
                end

                summary = value
                step()
            end,
            on_error = function(message)
                if job.cancelled or completed then
                    return
                end
                job.process = nil
                finish(false, tostring(message))
            end,
        })

        if not called then
            finish(false, tostring(process))
            return
        end

        if completed then
            return
        end

        job.process = process
        if not process then
            finish(false, 'failed to start the compaction request')
        end
    end

    step()
end

---Runs compaction and applies it to the session on success.
---
---@param session table
---@param config table
---@param options table|nil { system_prompt, context, extra_tokens, request }
---@param callback fun(ok: boolean, result: table|string)
---@return table job handle with a `kill` method
function Compaction.compact(session, config, options, callback)
    options = options or {}
    callback = callback or function() end

    local opts = Compaction.options(config)
    local job = make_job()
    local plan = Compaction.plan(session, config)

    if not plan then
        vim.schedule(function()
            if not job.cancelled then
                callback(true, { skipped = true, reason = 'nothing to compact' })
            end
        end)
        return job
    end

    run_compaction(session, prepare_compaction(session, config, options, opts, plan), job, callback)
    return job
end

---Formats the user-facing compaction summary for chat notices.
function Compaction.format_notice(result)
    return string.format(
        '[context compacted: %d messages summarized, ~%d -> ~%d tokens]',
        tonumber(result.summarized) or 0,
        tonumber(result.before_tokens) or 0,
        tonumber(result.after_tokens) or 0
    )
end

---Formats the "compaction started" notice.
function Compaction.format_progress(message_count)
    if message_count then
        return string.format('[compacting context (%d messages)...]', message_count)
    end
    return '[compacting context...]'
end

---Formats a compaction failure notice.
function Compaction.format_failure(message)
    return '[context compaction failed: ' .. tostring(message) .. ']'
end

return Compaction
