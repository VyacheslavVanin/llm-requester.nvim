local Tools = require('llm-requester.chat.agent.tools')

local Test = _G.Test
local uv = vim.uv or vim.loop

local base = vim.fn.tempname() .. '-llm-requester-tools'
vim.fn.mkdir(base .. '/sub', 'p')
local root = uv.fs_realpath(base)

local checks = {}

local permissions = {
    check = function(_, kind, request, callback)
        table.insert(checks, { kind = kind, request = request })
        callback({ allowed = true })
    end,
}

local tools = Tools.new({
    root = root,
    agent_config = {
        max_file_bytes = 1000,
        max_write_bytes = 1000,
        max_read_lines = 10,
        max_tool_output_bytes = 1000,
        max_list_entries = 10,
        command_timeout = 5,
    },
    permissions = permissions,
})

local function execute(name, arguments)
    local result
    local raw = type(arguments) == 'string' and arguments or vim.json.encode(arguments or {})
    tools:execute({
        id = 'call-1',
        type = 'function',
        ['function'] = { name = name, arguments = raw },
    }, function(value)
        result = value
    end)
    return result
end

local function execute_wait(name, arguments, runner)
    local active = runner or tools
    local done = false
    local result
    local raw = type(arguments) == 'string' and arguments or vim.json.encode(arguments or {})
    active:execute({
        id = 'call-1',
        type = 'function',
        ['function'] = { name = name, arguments = raw },
    }, function(value)
        result = value
        done = true
    end)
    vim.wait(10000, function()
        return done
    end)
    return result
end

local function read_file(path)
    local fd = uv.fs_open(path, 'r', 438)
    local content = fd and uv.fs_read(fd, 100000, 0) or nil
    if fd then
        uv.fs_close(fd)
    end
    return content
end

do
    vim.fn.writefile({ 'alpha', 'beta', 'gamma' }, root .. '/file.txt')
    checks = {}

    local result = execute('read_file', { path = 'file.txt' })
    Test.truthy(result:find('file.txt (3 lines)', 1, true), 'read reports the file and line count')
    Test.truthy(result:find('     1: alpha', 1, true), 'read returns numbered lines')
    Test.eq(#checks, 1, 'read asks permissions')
    Test.eq(checks[1].kind, 'read', 'read permission kind')
    Test.eq(checks[1].request.display, 'file.txt', 'read permission display path')

    local partial = execute('read_file', { path = 'file.txt', start_line = 2, max_lines = 1 })
    Test.truthy(partial:find('2: beta', 1, true), 'start_line offsets the first returned line')
    Test.falsy(partial:find('3: gamma', 1, true), 'max_lines limits the range')
    Test.truthy(partial:find('1 more line', 1, true), 'truncation is reported')

    Test.truthy(execute('read_file', { path = 'missing.txt' }):find('not found', 1, true), 'missing files are errors')
    Test.truthy(execute('read_file', { path = 'sub' }):find('not a regular file', 1, true), 'directories are rejected')
    Test.truthy(execute('read_file', { path = '' }):find('path is required', 1, true), 'empty paths are rejected')

    vim.fn.writefile({ string.rep('x', 1200) }, root .. '/big.txt')
    Test.truthy(execute('read_file', { path = 'big.txt' }):find('too large', 1, true), 'large files are rejected')
end

do
    local fd = uv.fs_open(root .. '/binary.bin', 'w', 420)
    uv.fs_write(fd, 'abc\0def', 0)
    uv.fs_close(fd)

    Test.truthy(execute('read_file', { path = 'binary.bin' }):find('binary', 1, true), 'binary files are rejected')

    vim.fn.writefile({}, root .. '/empty.txt')
    local empty = execute('read_file', { path = 'empty.txt' })
    Test.truthy(empty:find('0 lines', 1, true), 'empty files are readable')
    Test.truthy(empty:find('empty range', 1, true), 'empty files return an empty range')
end

do
    checks = {}

    local result = execute('write_file', { path = 'sub/new.txt', content = 'hello\nworld\n' })
    Test.truthy(result:find('wrote', 1, true), 'write reports success')
    Test.eq(read_file(root .. '/sub/new.txt'), 'hello\nworld\n', 'write stores the exact content')
    Test.eq(#checks, 1, 'write asks permissions')
    Test.eq(checks[1].kind, 'write', 'write permission kind')

    Test.truthy(execute('write_file', { path = 'missing/new.txt', content = 'x' }):find('parent directory', 1, true), 'missing parents are rejected')
    Test.truthy(execute('write_file', { path = 'sub/new.txt' }):find('content must be a string', 1, true), 'content is required')
    Test.truthy(execute('write_file', { path = 'sub', content = 'x' }):find('is a directory', 1, true), 'writing over a directory is rejected')
end

do
    vim.fn.writefile({ 'visible' }, root .. '/visible.txt')
    vim.fn.writefile({ 'hidden' }, root .. '/.secret')
    local outside = vim.fn.tempname() .. '-llm-requester-tools-outside'
    vim.fn.mkdir(outside, 'p')
    vim.fn.writefile({ 'outside' }, outside .. '/outside.txt')
    local outside_root = uv.fs_realpath(outside)
    checks = {}

    local visible = execute('list_directory', {})
    Test.truthy(visible:find('visible.txt', 1, true), 'visible files are listed')
    Test.truthy(visible:find('sub/', 1, true), 'directories are marked with a slash')
    Test.falsy(visible:find('.secret', 1, true), 'hidden entries are omitted by default')
    Test.eq(#checks, 0, 'listing visible entries needs no permission')

    local hidden = execute('list_directory', { include_hidden = true })
    Test.truthy(hidden:find('.secret', 1, true), 'hidden entries are listed when requested')
    Test.eq(#checks, 1, 'listing hidden entries asks permissions')
    Test.eq(checks[1].request.action, 'list hidden entries', 'hidden listing permission action')

    local external = execute('list_directory', { path = outside_root })
    Test.truthy(external:find('outside.txt', 1, true), 'external directories can be listed after approval')
    Test.eq(#checks, 2, 'external directory listings ask permissions')
    Test.eq(checks[2].request.action, 'list directory', 'external listing permission action')

    Test.truthy(execute('list_directory', { path = 'missing' }):find('not found', 1, true), 'missing directories are errors')

    vim.fn.delete(outside, 'rf')
end

do
    checks = {}

    local result = execute_wait('run_command', { command = 'echo hello' })
    Test.truthy(result and result:find('exit_code: 0', 1, true), 'command exit code is reported')
    Test.truthy(result and result:find('hello', 1, true), 'command stdout is returned')
    Test.eq(#checks, 1, 'commands ask permissions')
    Test.eq(checks[1].kind, 'command', 'command permission kind')

    local failed = execute_wait('run_command', { command = 'exit 7' })
    Test.truthy(failed and failed:find('exit_code: 7', 1, true), 'non-zero exit codes are reported')

    local denied_tools = Tools.new({
        root = root,
        agent_config = { command_timeout = 5 },
        permissions = {
            check = function(_, _, _, callback)
                callback({ allowed = false, reason = 'nope' })
            end,
        },
    })
    local denied = execute_wait('run_command', { command = 'echo hi' }, denied_tools)
    Test.truthy(denied and denied:find('command denied', 1, true), 'denied commands are reported')

    local timed = execute_wait('run_command', { command = 'sleep 5', timeout = 1 })
    Test.truthy(timed and timed:find('signal', 1, true), 'command timeout terminates the process')
end

do
    Test.truthy(execute('read_file', '{not json'):find('invalid arguments JSON', 1, true), 'invalid JSON is reported')
    Test.truthy(execute('unknown_tool', {}):find('unknown tool', 1, true), 'unknown tools are reported')
end

vim.fn.delete(base, 'rf')
