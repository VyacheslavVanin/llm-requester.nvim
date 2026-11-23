local Paths = require('llm-requester.chat.agent.paths')

local Test = _G.Test
local uv = vim.uv or vim.loop

local base = vim.fn.tempname() .. '-llm-requester-paths'
local outside = vim.fn.tempname() .. '-llm-requester-outside'

vim.fn.mkdir(base .. '/sub/deep', 'p')
vim.fn.mkdir(base .. '/submarine', 'p')
vim.fn.mkdir(outside, 'p')
vim.fn.writefile({ 'visible' }, base .. '/file.txt')
vim.fn.writefile({ 'hidden' }, base .. '/sub/.hidden')
vim.fn.writefile({ 'secret' }, outside .. '/secret.txt')

local root = uv.fs_realpath(base)
local outside_real = uv.fs_realpath(outside)
local link_ok = uv.fs_symlink(outside, base .. '/link')

do
    Test.eq(Paths.resolve(root, 'file.txt'), root .. '/file.txt', 'relative path is based on the root')
    Test.eq(Paths.resolve(root, 'sub/../file.txt'), root .. '/file.txt', 'parent segments are normalized')
    Test.eq(Paths.resolve(root, './sub/deep'), root .. '/sub/deep', 'current segments are normalized')
    Test.eq(Paths.resolve(root, 'missing/new.txt'), root .. '/missing/new.txt', 'missing paths keep their parent')
    Test.eq(Paths.resolve(root, '/'), '/', 'the filesystem root is preserved')

    local escaped = Paths.resolve(root, '../outside.txt')
    Test.truthy(escaped == nil or not Paths.is_within(escaped, root), 'escaping the root produces an outside path')
end

if link_ok then
    local via_link = Paths.resolve(root, 'link/secret.txt')
    Test.eq(via_link, outside_real .. '/secret.txt', 'symlinks are resolved to their real target')
    Test.falsy(Paths.is_within(via_link, root), 'a symlink cannot smuggle a path inside the root')

    uv.fs_symlink(outside .. '/missing.txt', base .. '/broken')
    local broken, broken_err = Paths.resolve(root, 'broken')
    Test.eq(broken, nil, 'unresolvable symlinks are rejected')
    Test.truthy(broken_err and broken_err:find('symlink', 1, true), 'broken symlink error is descriptive')
end

do
    Test.truthy(Paths.is_within(root, root), 'a path is within itself')
    Test.truthy(Paths.is_within(root .. '/sub', root), 'a child is within the root')
    Test.falsy(Paths.is_within(root .. '-sibling', root), 'prefix-only siblings are not within the root')
    Test.falsy(Paths.is_within('/etc/passwd', root), 'unrelated paths are outside')

    Test.eq(Paths.display(root, root), '.', 'root displays as a dot')
    Test.eq(Paths.display(root, root .. '/sub/file'), 'sub/file', 'inside paths display relative')
    Test.eq(Paths.display(root, '/etc/passwd'), '/etc/passwd', 'outside paths display absolute')

    Test.eq(Paths.dirname(root .. '/sub/file'), root .. '/sub', 'dirname of a nested file')
    Test.eq(Paths.dirname('/file'), '/', 'dirname at the filesystem root')
    Test.eq(Paths.basename(root .. '/sub/file'), 'file', 'basename of a nested file')
end

do
    Test.truthy(Paths.is_hidden(root, root .. '/.git/config'), 'a hidden component is detected')
    Test.truthy(Paths.is_hidden(root, root .. '/sub/.hidden'), 'nested hidden files are detected')
    Test.falsy(Paths.is_hidden(root, root .. '/sub/file'), 'visible paths are not hidden')
    Test.falsy(Paths.is_hidden(root, root), 'the root itself is not hidden')
    Test.truthy(Paths.is_hidden(root, outside_real .. '/.env'), 'hidden basenames outside the root are detected')
end

do
    Test.eq(Paths.resolve(root, ''), nil, 'empty paths are rejected')
    Test.eq(Paths.resolve(root, 'bad\0path'), nil, 'paths with NUL bytes are rejected')
end

vim.fn.delete(base, 'rf')
vim.fn.delete(outside, 'rf')
