local Permissions = require('llm-requester.chat.agent.permissions')
local Paths = require('llm-requester.chat.agent.paths')

local Test = _G.Test
local uv = vim.uv or vim.loop

local base = vim.fn.tempname() .. '-llm-requester-permissions'
local outside = vim.fn.tempname() .. '-llm-requester-permissions-outside'

vim.fn.mkdir(base .. '/sub', 'p')
vim.fn.mkdir(outside .. '/sub', 'p')
vim.fn.mkdir(outside .. '/submarine', 'p')

local root = uv.fs_realpath(base)
local outside_real = uv.fs_realpath(outside)
local limit = 2

local function request_for(path)
    local dir = Paths.dirname(path)
    return {
        path = path,
        dir = dir,
        display = Paths.display(root, path),
        display_dir = Paths.display(root, dir),
        hidden = Paths.is_hidden(root, path),
        within_root = Paths.is_within(path, root),
    }
end

local function make(selector)
    local prompts = {}
    local permissions = Permissions.new({
        root = root,
        agent_config = {
            auto_approve_limit = limit,
            confirm = function(request, choices, callback)
                table.insert(prompts, { request = request, choices = choices })
                callback(selector and selector(request, choices, #prompts) or 'deny')
            end,
        },
    })
    return permissions, prompts
end

local function check(permissions, kind, request)
    local result
    permissions:check(kind, request, function(decision)
        result = decision
    end)
    return result
end

do
    local permissions, prompts = make()
    local decision = check(permissions, 'read', request_for(root .. '/visible.txt'))
    Test.truthy(decision.allowed, 'visible files inside the root are readable by default')
    Test.eq(#prompts, 0, 'default reads do not prompt')
end

do
    local permissions, prompts = make(function()
        return 'once'
    end)

    Test.truthy(check(permissions, 'read', request_for(root .. '/.env')).allowed, 'hidden read can be allowed once')
    Test.eq(#prompts, 1, 'hidden files require a prompt')
    Test.truthy(check(permissions, 'read', request_for(root .. '/.env')).allowed, 'second hidden read is allowed again')
    Test.eq(#prompts, 2, 'a one-time grant is not remembered')
end

do
    local permissions, prompts = make(function()
        return 'file'
    end)

    Test.truthy(check(permissions, 'read', request_for(root .. '/.env')).allowed, 'hidden read can be granted')
    Test.eq(#prompts, 1, 'first hidden read prompts for a grant')
    Test.truthy(check(permissions, 'read', request_for(root .. '/.env')).allowed, 'granted hidden file stays readable')
    Test.eq(#prompts, 1, 'a file grant prevents further prompts inside the root')
end

do
    local permissions, prompts = make(function()
        return 'dir'
    end)

    Test.truthy(check(permissions, 'read', request_for(root .. '/sub/.secret')).allowed, 'hidden directory read is granted')
    for _ = 1, 5 do
        Test.truthy(check(permissions, 'read', request_for(root .. '/sub/.another')).allowed, 'a directory grant covers siblings')
    end
    Test.eq(#prompts, 1, 'directory grants inside the root are unlimited')
end

do
    local permissions, prompts = make(function()
        return 'file'
    end)

    Test.truthy(check(permissions, 'write', request_for(root .. '/new.txt')).allowed, 'write can be granted')
    Test.eq(#prompts, 1, 'writes always prompt before a grant exists')
    Test.truthy(check(permissions, 'write', request_for(root .. '/new.txt')).allowed, 'write grant is reused')
    Test.eq(#prompts, 1, 'a write grant prevents further prompts')
end

do
    local permissions, prompts = make(function()
        return 'dir'
    end)

    local first = outside_real .. '/sub/file.txt'
    Test.truthy(check(permissions, 'read', request_for(first)).allowed, 'outside read can be granted per directory')
    Test.eq(#prompts, 1, 'outside paths prompt')

    Test.truthy(check(permissions, 'read', request_for(outside_real .. '/sub/second.txt')).allowed, 'grant applies to the directory')
    Test.truthy(check(permissions, 'read', request_for(outside_real .. '/sub/third.txt')).allowed, 'grant has a limited budget')
    Test.eq(#prompts, 1, 'limited grant is used without prompting')

    Test.truthy(check(permissions, 'read', request_for(outside_real .. '/sub/fourth.txt')).allowed, 'exhausted grant prompts again')
    Test.eq(#prompts, 2, 'outside grants expire after the limit')

    Test.truthy(check(permissions, 'read', request_for(outside_real .. '/submarine/other.txt')).allowed, 'sibling directory prompts')
    Test.eq(#prompts, 3, 'directory grants do not leak to prefix siblings')
end

do
    local permissions, prompts = make(function(_, _, count)
        return count == 1 and 'exact' or 'deny'
    end)

    Test.truthy(check(permissions, 'command', { command = 'git status' }).allowed, 'commands are allowed through a prompt')
    Test.eq(#prompts, 1, 'first command prompts')
    Test.truthy(check(permissions, 'command', { command = 'git status' }).allowed, 'exact rule matches the same command')
    Test.truthy(check(permissions, 'command', { command = 'git status' }).allowed, 'exact rule has a limited budget')
    Test.eq(#prompts, 1, 'exact command rule prevents a prompt until the budget is spent')
    Test.falsy(check(permissions, 'command', { command = 'git status' }).allowed, 'expired exact rule prompts again')
    Test.eq(#prompts, 2, 'exact command rules expire after the limit')
end

do
    local permissions, prompts = make(function(_, _, count)
        return count == 1 and 'prefix' or 'deny'
    end)

    Test.truthy(check(permissions, 'command', { command = 'ls -la' }).allowed, 'prefix rule is created')
    Test.truthy(check(permissions, 'command', { command = 'ls src' }).allowed, 'prefix rule covers other arguments')
    Test.truthy(check(permissions, 'command', { command = 'ls src/lua' }).allowed, 'prefix budget is shared')
    Test.eq(#prompts, 1, 'prefix rule prevents prompts while the budget lasts')
    Test.falsy(check(permissions, 'command', { command = 'ls other' }).allowed, 'expired prefix rule prompts again')
    Test.eq(#prompts, 2, 'prefix rule expires after the limit')
end

do
    local permissions, prompts = make(function()
        return nil
    end)

    Test.falsy(check(permissions, 'write', request_for(root .. '/denied.txt')).allowed, 'escape/deny rejects the operation')
    Test.eq(#prompts, 1, 'denial is reported through the prompt')

    local empty = check(permissions, 'command', { command = '   ' })
    Test.falsy(empty.allowed, 'empty commands are rejected without a prompt')
    Test.eq(#prompts, 1, 'invalid commands do not open a prompt')
end

vim.fn.delete(base, 'rf')
vim.fn.delete(outside, 'rf')
