-- Agent tools: read/write files, list directories and run commands.
--
-- Every tool receives decoded arguments and reports a plain-text result through
-- a callback. User-facing errors are returned as text so the model can recover;
-- they never raise through the agent loop.

local Paths = require('llm-requester.chat.agent.paths')

local uv = vim.uv or vim.loop

local Tools = {}
Tools.__index = Tools

local SPECS = {
    {
        type = 'function',
        ['function'] = {
            name = 'read_file',
            description = 'Read a text file. Lines are returned with 1-based line numbers.',
            parameters = {
                type = 'object',
                properties = {
                    path = { type = 'string', description = 'File path, absolute or relative to the working directory.' },
                    start_line = { type = 'integer', description = 'First line to return (1-based). Defaults to 1.' },
                    max_lines = { type = 'integer', description = 'Maximum number of lines to return.' },
                },
                required = { 'path' },
            },
        },
    },
    {
        type = 'function',
        ['function'] = {
            name = 'write_file',
            description = 'Create or overwrite a text file. The parent directory must already exist.',
            parameters = {
                type = 'object',
                properties = {
                    path = { type = 'string', description = 'File path, absolute or relative to the working directory.' },
                    content = { type = 'string', description = 'Complete new file content.' },
                },
                required = { 'path', 'content' },
            },
        },
    },
    {
        type = 'function',
        ['function'] = {
            name = 'list_directory',
            description = 'List entries of a directory. Hidden entries are listed only when explicitly requested and approved.',
            parameters = {
                type = 'object',
                properties = {
                    path = { type = 'string', description = 'Directory path. Defaults to the working directory.' },
                    include_hidden = { type = 'boolean', description = 'Include dotfiles and dot-directories.' },
                },
                required = {},
            },
        },
    },
    {
        type = 'function',
        ['function'] = {
            name = 'run_command',
            description = 'Run a shell command inside the session working directory and return its output.',
            parameters = {
                type = 'object',
                properties = {
                    command = { type = 'string', description = 'Command line executed with sh -c.' },
                    timeout = { type = 'integer', description = 'Timeout in seconds.' },
                },
                required = { 'command' },
            },
        },
    },
}

local function truncate(text, limit, note)
    local value = tostring(text or '')
    if #value <= limit then
        return value
    end
    return value:sub(1, limit) .. '\n... truncated' .. (note and (' ' .. note) or '') .. ' ...'
end

local function error_result(message)
    return 'error: ' .. tostring(message)
end

---Returns a deep copy of the tool declarations sent to the LLM.
function Tools.specs()
    return vim.deepcopy(SPECS)
end

function Tools.new(options)
    options = options or {}
    return setmetatable({
        root = options.root or vim.fn.getcwd(),
        config = options.agent_config or {},
        permissions = options.permissions,
    }, Tools)
end

function Tools:_limit(key, default)
    local value = tonumber(self.config[key])
    if value and value > 0 then
        return value
    end
    return default
end

function Tools:_resolve(path)
    return Paths.resolve(self.root, path)
end

function Tools:_request_for(path, action)
    local within_root = Paths.is_within(path, self.root)
    local dir = Paths.dirname(path)

    return {
        path = path,
        display = Paths.display(self.root, path),
        display_dir = Paths.display(self.root, dir),
        dir = dir,
        hidden = Paths.is_hidden(self.root, path),
        within_root = within_root,
        action = action,
    }
end

function Tools:_read_handler(args, callback)
    if type(args.path) ~= 'string' or args.path == '' then
        return callback(error_result('path is required'))
    end

    local path, resolve_err = self:_resolve(args.path)
    if not path then
        return callback(error_result(resolve_err))
    end

    local request = self:_request_for(path, 'read file')
    self.permissions:check('read', request, function(decision)
        if not decision.allowed then
            return callback(error_result('read denied: ' .. tostring(decision.reason)))
        end

        local stat = uv.fs_stat(path)
        if not stat then
            return callback(error_result('file not found: ' .. args.path))
        end
        if stat.type ~= 'file' then
            return callback(error_result(args.path .. ' is not a regular file'))
        end

        local max_bytes = self:_limit('max_file_bytes', 200000)
        if stat.size > max_bytes then
            return callback(error_result(string.format(
                'file is too large (%d bytes, limit %d); raise agent.max_file_bytes',
                stat.size,
                max_bytes
            )))
        end

        local fd, open_err = uv.fs_open(path, 'r', 438)
        if not fd then
            return callback(error_result('cannot open file: ' .. tostring(open_err)))
        end

        local content = uv.fs_read(fd, stat.size, 0)
        uv.fs_close(fd)

        if not content then
            return callback(error_result('cannot read file'))
        end
        if content:find('\0', 1, true) then
            return callback(error_result('binary file, refusing to read'))
        end

        local lines = vim.split(content, '\n', { plain = true })
        if #lines > 0 and lines[#lines] == '' then
            table.remove(lines)
        end

        local start_line = math.max(1, math.floor(tonumber(args.start_line) or 1))
        local max_lines = math.min(
            self:_limit('max_read_lines', 2000),
            math.max(1, math.floor(tonumber(args.max_lines) or self:_limit('max_read_lines', 2000)))
        )

        local header = string.format('%s (%d lines)', request.display, #lines)
        if start_line > #lines then
            return callback(header .. '\n(empty range)')
        end

        local result = {}
        local last_line = math.min(#lines, start_line + max_lines - 1)
        for index = start_line, last_line do
            table.insert(result, string.format('%6d: %s', index, lines[index]))
        end

        local body = #result > 0 and table.concat(result, '\n') or '(empty range)'
        local note = ''
        if last_line < #lines then
            note = string.format(
                '\n... %d more lines; continue with start_line=%d ...',
                #lines - last_line,
                last_line + 1
            )
        end

        callback(header .. '\n' .. body .. note)
    end)
end

function Tools:_write_handler(args, callback)
    if type(args.path) ~= 'string' or args.path == '' then
        return callback(error_result('path is required'))
    end
    if type(args.content) ~= 'string' then
        return callback(error_result('content must be a string'))
    end
    if #args.content > self:_limit('max_write_bytes', 200000) then
        return callback(error_result('content is too large; raise agent.max_write_bytes'))
    end

    local path, resolve_err = self:_resolve(args.path)
    if not path then
        return callback(error_result(resolve_err))
    end

    local request = self:_request_for(path, 'write file')
    self.permissions:check('write', request, function(decision)
        if not decision.allowed then
            return callback(error_result('write denied: ' .. tostring(decision.reason)))
        end

        local stat = uv.fs_stat(path)
        if stat and stat.type == 'directory' then
            return callback(error_result(args.path .. ' is a directory'))
        end

        local parent = Paths.dirname(path)
        local parent_stat = uv.fs_stat(parent)
        if not parent_stat or parent_stat.type ~= 'directory' then
            return callback(error_result('parent directory does not exist: ' .. Paths.display(self.root, parent)))
        end

        local fd, open_err = uv.fs_open(path, 'w', 420)
        if not fd then
            return callback(error_result('cannot open file for writing: ' .. tostring(open_err)))
        end

        local written, write_err = uv.fs_write(fd, args.content, 0)
        uv.fs_close(fd)

        if not written then
            return callback(error_result('cannot write file: ' .. tostring(write_err)))
        end

        callback(string.format(
            'wrote %d bytes to %s',
            written,
            request.display
        ))
    end)
end

function Tools:_list(path, include_hidden, callback)
    local handle, scan_err = uv.fs_scandir(path)
    if not handle then
        return callback(error_result('cannot list directory: ' .. tostring(scan_err)))
    end

    local limit = self:_limit('max_list_entries', 500)
    local entries = {}

    while true do
        local name, entry_type = uv.fs_scandir_next(handle)
        if not name then
            break
        end

        local hidden = name:sub(1, 1) == '.'
        if include_hidden or not hidden then
            table.insert(entries, {
                name = name,
                type = entry_type,
            })
        end
    end

    table.sort(entries, function(left, right)
        return left.name < right.name
    end)

    local lines = {}
    for index, entry in ipairs(entries) do
        if index > limit then
            table.insert(lines, string.format('... %d more entries ...', #entries - limit))
            break
        end
        local suffix = entry.type == 'directory' and '/' or ''
        table.insert(lines, entry.name .. suffix)
    end

    local header = string.format('%s (%d entries)', Paths.display(self.root, path), #entries)
    callback(header .. '\n' .. (#lines > 0 and table.concat(lines, '\n') or '(empty directory)'))
end

function Tools:_list_handler(args, callback)
    local path
    if args.path == nil or args.path == '' then
        path = self.root
    else
        if type(args.path) ~= 'string' then
            return callback(error_result('path must be a string'))
        end
        local resolve_err
        path, resolve_err = self:_resolve(args.path)
        if not path then
            return callback(error_result(resolve_err))
        end
    end

    local include_hidden = args.include_hidden and true or false

    local function run(allow_hidden)
        local stat = uv.fs_stat(path)
        if not stat then
            return callback(error_result('directory not found: ' .. tostring(args.path or path)))
        end
        if stat.type ~= 'directory' then
            return callback(error_result(tostring(args.path or path) .. ' is not a directory'))
        end
        self:_list(path, allow_hidden, callback)
    end

    if not include_hidden and Paths.is_within(path, self.root) then
        return run(false)
    end

    local request = self:_request_for(
        path,
        include_hidden and 'list hidden entries' or 'list directory'
    )
    if include_hidden then
        request.hidden = true
    end
    -- Approving a listing grants the directory itself, not its parent.
    request.dir = path
    request.display_dir = Paths.display(self.root, path)

    self.permissions:check('read', request, function(decision)
        if not decision.allowed then
            return callback(error_result('directory listing denied: ' .. tostring(decision.reason)))
        end
        run(include_hidden)
    end)
end

function Tools:_command_handler(args, callback)
    if type(args.command) ~= 'string' or args.command:match('^%s*$') then
        return callback(error_result('command is required'))
    end
    if #args.command > 4000 then
        return callback(error_result('command is too long'))
    end

    local request = {
        command = args.command,
        display = args.command,
    }

    self.permissions:check('command', request, function(decision)
        if not decision.allowed then
            return callback(error_result('command denied: ' .. tostring(decision.reason)))
        end

        local timeout_seconds = math.min(600, math.max(1, math.floor(tonumber(args.timeout) or self:_limit('command_timeout', 60))))

        local started, process = pcall(vim.system, { 'sh', '-c', args.command }, {
            cwd = self.root,
            text = true,
            timeout = timeout_seconds * 1000,
        }, function(obj)
            vim.schedule(function()
                local exit_code
                if obj.signal and obj.signal ~= 0 then
                    exit_code = 'signal ' .. tostring(obj.signal)
                else
                    exit_code = tostring(obj.code)
                end

                local parts = { 'exit_code: ' .. exit_code }
                local has_output = false

                if obj.stdout and obj.stdout ~= '' then
                    table.insert(parts, 'stdout:\n' .. obj.stdout:gsub('%s+$', ''))
                    has_output = true
                end
                if obj.stderr and obj.stderr ~= '' then
                    table.insert(parts, 'stderr:\n' .. obj.stderr:gsub('%s+$', ''))
                    has_output = true
                end
                if not has_output then
                    table.insert(parts, '(no output)')
                end

                callback(truncate(table.concat(parts, '\n'), self:_limit('max_tool_output_bytes', 50000)))
            end)
        end)

        if not started then
            return callback(error_result('cannot start command: ' .. tostring(process)))
        end

        self._running = process
    end)
end

---Kills a command started by the agent, if any.
function Tools:kill()
    if self._running then
        pcall(function()
            self._running:kill(9)
        end)
        self._running = nil
    end
end

local HANDLERS = {
    read_file = Tools._read_handler,
    write_file = Tools._write_handler,
    list_directory = Tools._list_handler,
    run_command = Tools._command_handler,
}

---Executes one tool call. The result is always a string, including failures.
---@param call table
---@param callback fun(result: string)
function Tools:execute(call, callback)
    if type(call) ~= 'table' or type(call['function']) ~= 'table' then
        return callback(error_result('invalid tool call'))
    end

    local name = call['function'].name
    local handler = HANDLERS[name]
    if not handler then
        return callback(error_result('unknown tool: ' .. tostring(name)))
    end

    local raw_arguments = call['function'].arguments
    local arguments = {}
    if type(raw_arguments) == 'string' and raw_arguments:match('%S') then
        local ok, decoded = pcall(vim.json.decode, raw_arguments)
        if not ok or type(decoded) ~= 'table' then
            return callback(error_result('invalid arguments JSON: ' .. tostring(decoded)))
        end
        arguments = decoded
    elseif type(raw_arguments) == 'table' then
        arguments = raw_arguments
    end

    local ok, err = pcall(function()
        handler(self, arguments, callback)
    end)
    if not ok then
        callback(error_result(err))
    end
end

return Tools
