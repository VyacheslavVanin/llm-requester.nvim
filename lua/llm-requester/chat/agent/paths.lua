-- Path handling for the agent tools.
--
-- Paths are resolved segment by segment so that symlinks are followed the same
-- way the operating system follows them. That makes it impossible to escape an
-- allowed directory with a combination like "link/../../etc": every existing
-- prefix is replaced with its real path before the next segment is applied.

local uv = vim.uv or vim.loop

local Paths = {}

local function expand_home(path)
    if path == '~' then
        return vim.fn.expand('~')
    end
    if path:sub(1, 2) == '~/' then
        return vim.fn.expand('~') .. path:sub(2)
    end
    return path
end

local function parent_of(path)
    return path:match('^(.*)/[^/]*$') or ''
end

---Resolves a path to its canonical absolute form.
--
-- `base` is used for relative paths (the default is the current working
-- directory). The result never contains "." or ".." components.
---@param base string|nil
---@param input string
---@return string|nil path
---@return string|nil err
function Paths.resolve(base, input)
    if type(input) ~= 'string' or input == '' then
        return nil, 'path is empty'
    end
    if input:find('\0', 1, true) then
        return nil, 'path contains a NUL byte'
    end

    local expanded = expand_home(input)
    local base_dir = base
    if type(base_dir) ~= 'string' or base_dir == '' then
        base_dir = uv.cwd() or vim.fn.getcwd()
    end

    local absolute
    if expanded:sub(1, 1) == '/' then
        absolute = expanded
    else
        absolute = base_dir .. '/' .. expanded
    end

    local resolved = ''
    for part in absolute:gmatch('[^/]+') do
        if part == '.' then
            -- A no-op segment.
        elseif part == '..' then
            if resolved ~= '' then
                resolved = parent_of(resolved)
            end
        else
            local candidate = resolved .. '/' .. part
            local real = uv.fs_realpath(candidate)
            if real then
                resolved = real
            else
                -- A symlink that cannot be resolved (broken link, loop) must
                -- never be treated as a path inside the allowed root: writing
                -- through it could create the target outside the root.
                local link_stat = uv.fs_lstat(candidate)
                if link_stat and link_stat.type == 'link' then
                    return nil, 'path traverses an unresolvable symlink: ' .. candidate
                end
                resolved = candidate
            end
        end
    end

    if resolved == '' then
        resolved = '/'
    end

    return resolved
end

---Canonicalizes an absolute or relative path against the process cwd.
function Paths.canonical(path)
    return Paths.resolve(nil, path)
end

---Returns true when `path` is `root` itself or lives below it.
function Paths.is_within(path, root)
    if type(path) ~= 'string' or type(root) ~= 'string' then
        return false
    end
    if path == root then
        return true
    end

    local prefix = root == '/' and '/' or root .. '/'
    return path:sub(1, #prefix) == prefix
end

---Returns the path relative to `root`, or the path itself when outside it.
function Paths.display(root, path)
    if Paths.is_within(path, root) then
        if path == root then
            return '.'
        end
        return path:sub(#root + 2)
    end
    return path
end

---Returns true when any component of a path inside `root` starts with a dot.
--
-- Hidden files outside the allowed root are reported by their basename; those
-- paths require approval anyway.
function Paths.is_hidden(root, path)
    if type(path) ~= 'string' then
        return false
    end

    local relative
    if Paths.is_within(path, root) then
        relative = path == root and '' or path:sub(#root + 2)
    else
        relative = path:match('([^/]+)$') or path
    end

    for part in relative:gmatch('[^/]+') do
        if part ~= '.' and part ~= '..' and part:sub(1, 1) == '.' then
            return true
        end
    end
    return false
end

---Returns the parent directory of an absolute path.
function Paths.dirname(path)
    if type(path) ~= 'string' or path == '/' then
        return '/'
    end
    local parent = parent_of(path)
    if parent == '' then
        return '/'
    end
    return parent
end

---Returns the last component of a path.
function Paths.basename(path)
    if type(path) ~= 'string' then
        return ''
    end
    return path:match('([^/]+)$') or path
end

return Paths
