-- Permission layer for agent tools.
--
-- Grants are kept in memory for the lifetime of an agent session. Reading
-- visible files inside the session root is allowed by default; everything
-- else is confirmed through a user prompt. Directory and file grants created
-- inside the root are unlimited, grants outside the root and all command rules
-- expire after `auto_approve_limit` uses.

local Paths = require('llm-requester.chat.agent.paths')

local Permissions = {}
Permissions.__index = Permissions

local DEFAULT_LIMIT = 20

local function default_confirm(request, choices, callback)
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

local function trim(text)
    return tostring(text or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function truncate(text, limit)
    local value = tostring(text or '')
    if #value <= limit then
        return value
    end
    return value:sub(1, limit) .. '...'
end

local function command_prefix(command)
    return command:match('^%s*(%S+)') or ''
end

local function usable(entry)
    if not entry then
        return false
    end
    if entry.remaining == nil then
        return true
    end
    return entry.remaining > 0
end

local function use_entry(entry)
    if entry.remaining ~= nil then
        entry.remaining = entry.remaining - 1
    end
end

local function find_dir_grant(grants, path)
    local best_dir

    for dir, entry in pairs(grants) do
        if usable(entry) and Paths.is_within(path, dir) then
            if not best_dir or #dir > #best_dir then
                best_dir = dir
            end
        end
    end

    return best_dir and grants[best_dir] or nil
end

function Permissions.new(options)
    options = options or {}
    local agent_config = options.agent_config or {}
    local limit = tonumber(agent_config.auto_approve_limit)

    return setmetatable({
        root = options.root or vim.fn.getcwd(),
        limit = math.max(1, math.floor(limit or DEFAULT_LIMIT)),
        allow_read_visible_in_cwd = agent_config.allow_read_visible_in_cwd ~= false,
        confirm = agent_config.confirm or default_confirm,
        read_files = {},
        read_dirs = {},
        write_files = {},
        write_dirs = {},
        command_rules = {},
        prompts = 0,
    }, Permissions)
end

function Permissions:reset()
    self.read_files = {}
    self.read_dirs = {}
    self.write_files = {}
    self.write_dirs = {}
    self.command_rules = {}
end

function Permissions:_grant_scope(path)
    if Paths.is_within(path, self.root) then
        return nil
    end
    return self.limit
end

function Permissions:_grant_file(kind, path)
    local files = kind == 'read' and self.read_files or self.write_files
    files[path] = { remaining = self:_grant_scope(path) }
end

function Permissions:_grant_dir(kind, dir)
    local dirs = kind == 'read' and self.read_dirs or self.write_dirs
    dirs[dir] = { remaining = self:_grant_scope(dir) }
end

function Permissions:_add_command_rule(kind, value)
    table.insert(self.command_rules, {
        kind = kind,
        value = value,
        remaining = self.limit,
    })
end

function Permissions:_find_command_rule(command, prefix)
    for _, rule in ipairs(self.command_rules) do
        if usable(rule) and rule.kind == 'exact' and rule.value == command then
            return rule
        end
    end

    for _, rule in ipairs(self.command_rules) do
        if usable(rule) and rule.kind == 'prefix' and rule.value == prefix then
            return rule
        end
    end

    return nil
end

function Permissions:_consume_file(kind, path)
    local files = kind == 'read' and self.read_files or self.write_files
    local entry = files[path]
    if usable(entry) then
        use_entry(entry)
        return true
    end
    return false
end

function Permissions:_consume_dir(kind, path)
    local dirs = kind == 'read' and self.read_dirs or self.write_dirs
    local entry = find_dir_grant(dirs, path)
    if usable(entry) then
        use_entry(entry)
        return true
    end
    return false
end

-- Decides whether an operation can proceed without asking the user.
-- Returns a decision table or nil when confirmation is required.
function Permissions:_evaluate(kind, request)
    local path = request.path

    if kind == 'command' then
        local command = trim(request.command)
        if command == '' then
            return { allowed = false, reason = 'empty command' }
        end

        local rule = self:_find_command_rule(command, command_prefix(command))
        if rule then
            use_entry(rule)
            return { allowed = true, grant = rule.kind }
        end
        return nil
    end

    if type(path) ~= 'string' then
        return { allowed = false, reason = 'path is missing' }
    end

    if self:_consume_file(kind, path) then
        return { allowed = true, grant = 'file' }
    end

    if self:_consume_dir(kind, path) then
        return { allowed = true, grant = 'dir' }
    end

    if kind == 'read' and self.allow_read_visible_in_cwd
        and request.within_root and not request.hidden then
        return { allowed = true, grant = 'default' }
    end

    return nil
end

local function choice(id, label)
    return { id = id, label = label }
end

local function scope_label(limited, limit)
    if limited then
        return string.format(' (auto-approve, %d uses)', limit)
    end
    return ' (unlimited inside the working directory)'
end

function Permissions:_file_choices(kind, request)
    local limited = request.within_root ~= true
    local listing = type(request.action) == 'string' and request.action:match('^list') ~= nil
    local file_label
    if listing then
        file_label = 'Allow this directory for the session'
    elseif kind == 'read' then
        file_label = 'Allow this file for the session'
    else
        file_label = 'Allow writing this file for the session'
    end

    return {
        choice('once', 'Allow once'),
        choice('file', file_label .. scope_label(limited, self.limit)),
        choice('dir', string.format(
            'Allow directory %s for the session%s',
            truncate(request.display_dir or '.', 80),
            scope_label(limited, self.limit)
        )),
        choice('deny', 'Deny'),
    }
end

function Permissions:_command_choices(request)
    local prefix = command_prefix(request.command)
    return {
        choice('once', 'Allow once'),
        choice('exact', string.format('Allow this exact command (%d uses)', self.limit)),
        choice('prefix', string.format('Allow all "%s" commands (%d uses)', truncate(prefix, 40), self.limit)),
        choice('deny', 'Deny'),
    }
end

function Permissions:_prompt(kind, request, callback)
    self.prompts = self.prompts + 1

    local choices
    if kind == 'command' then
        choices = self:_command_choices(request)
    else
        choices = self:_file_choices(kind, request)
    end

    local prompt
    if kind == 'command' then
        prompt = 'Allow command: ' .. truncate(trim(request.command), 120) .. '?'
    elseif kind == 'read' then
        prompt = 'Allow read access to ' .. truncate(request.display or request.path, 120) .. '?'
    else
        prompt = 'Allow write access to ' .. truncate(request.display or request.path, 120) .. '?'
    end

    local confirm_request = {
        prompt = prompt,
        kind = kind,
        path = request.path,
        command = request.command,
        display = request.display,
    }

    local function finish(selected)
        if selected == nil or selected == 'deny' then
            callback({ allowed = false, reason = 'denied by the user' })
            return
        end

        if selected == 'once' then
            callback({ allowed = true, grant = 'once' })
            return
        end

        if kind == 'command' then
            local value = selected == 'exact' and trim(request.command) or command_prefix(request.command)
            self:_add_command_rule(selected, value)
        elseif selected == 'file' then
            self:_grant_file(kind, request.path)
        elseif selected == 'dir' then
            self:_grant_dir(kind, request.dir or Paths.dirname(request.path))
        end

        callback({ allowed = true, grant = selected })
    end

    self.confirm(confirm_request, choices, finish)
end

---Checks an operation.
--
-- `kind` is one of "read", "write" or "command". For file operations the
-- request must provide `path` (canonical), `display`, `hidden`, `within_root`
-- and optionally `dir`/`display_dir`. For commands it must provide `command`.
---@param kind string
---@param request table
---@param callback fun(decision: table)
function Permissions:check(kind, request, callback)
    local decision = self:_evaluate(kind, request)
    if decision then
        callback(decision)
        return
    end
    self:_prompt(kind, request, callback)
end

return Permissions
