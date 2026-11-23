-- Agent orchestrator.
--
-- One round sends the conversation to the LLM. When the model asks for tools,
-- each call is approved, executed and appended to the history before the next
-- round starts. The UI is decoupled through the `events` table supplied by
-- llm-requester.chat.

local Client = require('llm-requester.chat.client')
local Paths = require('llm-requester.chat.agent.paths')
local Permissions = require('llm-requester.chat.agent.permissions')
local Tools = require('llm-requester.chat.agent.tools')

local Agent = {}
Agent.__index = Agent

local DEFAULT_MAX_ROUNDS = 24

local function default_limit_confirm(request, choices, callback)
    vim.schedule(function()
        vim.ui.select(choices, {
            prompt = request.prompt,
            format_item = function(item)
                return item.label
            end,
        }, function(item)
            callback(item and item.id or nil)
        end)
    end)
end

local function truncate(text, limit)
    local value = tostring(text or '')
    if #value <= limit then
        return value
    end
    return value:sub(1, limit) .. '\n... truncated in stored session ...'
end

local function build_system_prompt(agent_config, root)
    local prompt = type(agent_config.system_prompt) == 'string' and agent_config.system_prompt or ''
    return table.concat({
        prompt,
        '',
        'Working directory: ' .. root,
        'Paths passed to the tools may be absolute or relative to the working directory.',
        'The working directory itself cannot be changed.',
        'Some actions require explicit user approval and may be denied. If an action is denied,',
        'do not retry it without a reason: explain the situation to the user or choose another approach.',
    }, '\n')
end

function Agent.new(options)
    options = options or {}

    local config = options.config or {}
    local agent_config = config.agent or {}
    local session = options.session
    local cwd = (session and (session.root or session.cwd)) or vim.fn.getcwd()
    local root = Paths.canonical(cwd) or cwd
    local permissions = Permissions.new({
        root = root,
        agent_config = agent_config,
    })
    local base_max_rounds = math.max(1, math.floor(tonumber(agent_config.max_tool_iterations) or DEFAULT_MAX_ROUNDS))

    return setmetatable({
        config = config,
        session = session,
        root = root,
        events = {},
        pending = false,
        process = nil,
        token = 0,
        rounds = 0,
        context = '',
        base_max_rounds = base_max_rounds,
        max_rounds = base_max_rounds,
        iteration_step = math.max(1, math.floor(tonumber(agent_config.iteration_limit_step) or base_max_rounds)),
        confirm_limit = agent_config.confirm_iteration_limit or default_limit_confirm,
        max_calls_per_round = math.max(1, math.floor(tonumber(agent_config.max_tool_calls_per_round) or 20)),
        max_stored_output = math.max(100, math.floor(tonumber(agent_config.max_stored_tool_output) or 8000)),
        permissions = permissions,
        tools = Tools.new({
            root = root,
            agent_config = agent_config,
            permissions = permissions,
        }),
    }, Agent)
end

function Agent:_emit(name, ...)
    local handler = self.events[name]
    if handler then
        handler(...)
    end
end

function Agent:_stale(token)
    return token ~= self.token or not self.pending
end

function Agent:_request(token)
    if self:_stale(token) then
        return
    end

    self.rounds = self.rounds + 1
    self:_emit('on_assistant_start')

    local messages = self.session:build_messages(
        build_system_prompt(self.config.agent or {}, self.root),
        self.context
    )

    self.process = Client.request({
        config = self.config,
        messages = messages,
        tools = Tools.specs(),
        tool_choice = (self.config.agent or {}).tool_choice,
        on_delta = function(chunk)
            if self:_stale(token) then
                return
            end
            self:_emit('on_delta', chunk)
        end,
        on_usage = function(usage)
            if self:_stale(token) then
                return
            end
            self:_emit('on_usage', usage)
        end,
        on_finish = function(content, tool_calls, finish_reason)
            if self:_stale(token) then
                return
            end

            self.process = nil
            tool_calls = tool_calls or {}

            if #tool_calls == 0 then
                self.pending = false
                self.session:add_assistant(content or '')
                self:_emit('on_change')
                self:_emit('on_finish', content or '', finish_reason)
                return
            end

            self:_handle_tool_calls(content or '', tool_calls, token)
        end,
        on_error = function(message)
            if self:_stale(token) then
                return
            end

            self.process = nil
            self.pending = false
            self:_emit('on_error', message)
        end,
    })
end

function Agent:_run_tool_calls(tool_calls, token)
    local index = 0

    local function next_call()
        if self:_stale(token) then
            return
        end

        index = index + 1
        if index > #tool_calls then
            self:_request(token)
            return
        end

        local call = tool_calls[index]
        self:_emit('on_tool_start', call)

        if index > self.max_calls_per_round then
            local result = 'error: too many tool calls in one round, not executed'
            self.session:add_tool_result(call.id, result, call['function'].name)
            self:_emit('on_tool_result', call, result)
            self:_emit('on_change')
            next_call()
            return
        end

        self.tools:execute(call, function(result)
            if self:_stale(token) then
                return
            end

            self.session:add_tool_result(
                call.id,
                truncate(result, self.max_stored_output),
                call['function'].name
            )
            self:_emit('on_tool_result', call, result)
            self:_emit('on_change')
            next_call()
        end)
    end

    next_call()
end

function Agent:_stop_at_limit(tool_calls)
    for _, call in ipairs(tool_calls) do
        self.session:add_tool_result(
            call.id,
            'error: tool iteration limit reached; the user chose to stop',
            call['function'].name
        )
    end
    self:_emit('on_change')
    self:_emit('on_notice', string.format(
        'agent stopped at the tool iteration limit (%d rounds); '
            .. 'raise agent.max_tool_iterations or approve more rounds next time',
        self.rounds
    ))
    self.pending = false
    self.process = nil
    self:_emit('on_finish', '')
end

function Agent:_ask_continue(tool_calls, token)
    self:_emit('on_notice', string.format(
        'tool iteration limit reached (%d rounds), waiting for confirmation',
        self.rounds
    ))

    local choices = {
        {
            id = 'continue',
            label = string.format('Continue with %d more rounds', self.iteration_step),
        },
        { id = 'stop', label = 'Stop here' },
    }

    local function finish(selected)
        if self:_stale(token) then
            return
        end

        if selected == 'continue' then
            self.max_rounds = self.rounds + self.iteration_step
            self:_emit('on_notice', string.format(
                'continuing; tool iteration limit raised to %d rounds',
                self.max_rounds
            ))
            self:_run_tool_calls(tool_calls, token)
            return
        end

        self:_stop_at_limit(tool_calls)
    end

    self.confirm_limit({
        prompt = string.format('Agent reached the tool iteration limit (%d). Continue?', self.rounds),
        rounds = self.rounds,
        max_rounds = self.max_rounds,
        step = self.iteration_step,
    }, choices, finish)
end

function Agent:_handle_tool_calls(content, tool_calls, token)
    self.session:add_assistant(content, tool_calls)
    self:_emit('on_change')

    if self.rounds >= self.max_rounds then
        self:_ask_continue(tool_calls, token)
        return
    end

    self:_run_tool_calls(tool_calls, token)
end

---Starts a new agent exchange. The user message must already be in the session.
---@param events table
---@param context string|nil
function Agent:send(events, context)
    self.events = events or {}
    self.context = context or ''
    self.pending = true
    self.token = self.token + 1
    self.rounds = 0
    self.max_rounds = self.base_max_rounds

    local token = self.token
    self:_request(token)
    return token
end

function Agent:is_pending()
    return self.pending
end

---Cancels the active exchange and kills any running process.
function Agent:cancel()
    self.token = self.token + 1
    self.pending = false

    if self.process then
        pcall(function()
            self.process:kill(9)
        end)
        self.process = nil
    end

    self.tools:kill()
end

return Agent
