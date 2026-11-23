-- Persistent storage for chat sessions.
--
-- Every session is a separate JSON file. Writes go through a temporary file
-- followed by an atomic rename, so a crash in the middle of a save cannot
-- corrupt an existing chat.

local Session = require('llm-requester.chat.session')

local Store = {}
Store.__index = Store

local id_counter = 0

local function generate_id()
    id_counter = id_counter + 1
    return string.format('%s-%d-%d', os.date('%Y%m%d-%H%M%S'), vim.fn.getpid(), id_counter)
end

local function normalize_dir(dir)
    local normalized = tostring(dir or ''):gsub('/+$', '')
    return normalized == '' and '.' or normalized
end

function Store.new(dir)
    return setmetatable({ dir = normalize_dir(dir) }, Store)
end

function Store:path(id)
    return self.dir .. '/' .. id .. '.json'
end

function Store:save(session)
    local ok, result = pcall(vim.fn.mkdir, self.dir, 'p')
    if not ok then
        return false, result
    end
    if result == 0 and vim.fn.isdirectory(self.dir) == 0 then
        return false, 'failed to create sessions directory: ' .. self.dir
    end

    session:touch()

    local encoded_ok, encoded = pcall(vim.json.encode, session:to_table())
    if not encoded_ok then
        return false, encoded
    end

    local path = self:path(session.id)
    local temporary_path = path .. '.tmp'

    local write_ok, write_err = pcall(vim.fn.writefile, { encoded }, temporary_path)
    if not write_ok then
        return false, write_err
    end

    local rename_ok, rename_err = vim.uv.fs_rename(temporary_path, path)
    if not rename_ok then
        os.remove(temporary_path)
        return false, rename_err
    end

    return true
end

function Store:load(id)
    local path = self:path(id)
    if vim.fn.filereadable(path) ~= 1 then
        return nil, 'session not found: ' .. tostring(id)
    end

    local read_ok, lines = pcall(vim.fn.readfile, path)
    if not read_ok then
        return nil, lines
    end

    local decode_ok, decoded = pcall(vim.json.decode, table.concat(lines, '\n'))
    if not decode_ok then
        return nil, decoded
    end

    local session = Session.from_table(decoded)
    if not session then
        return nil, 'invalid session format: ' .. tostring(id)
    end

    return session
end

function Store:list()
    local entries = {}
    local files = vim.fn.glob(self.dir .. '/*.json', false, true)

    for _, path in ipairs(files) do
        local id = vim.fn.fnamemodify(path, ':t:r')
        local session = self:load(id)
        if session then
            table.insert(entries, {
                id = id,
                path = path,
                session = session,
            })
        end
    end

    table.sort(entries, function(left, right)
        return (left.session.updated_at or 0) > (right.session.updated_at or 0)
    end)

    return entries
end

function Store:latest(cwd)
    for _, entry in ipairs(self:list()) do
        if entry.session.cwd == cwd and not entry.session:is_empty() then
            return entry.session
        end
    end
    return nil
end

function Store:delete(id)
    local path = self:path(id)
    if vim.fn.filereadable(path) == 0 then
        return true
    end

    local ok, err = vim.uv.fs_unlink(path)
    if not ok then
        return false, err
    end

    return true
end

function Store:new_session(cwd, model)
    return Session.new({
        id = generate_id(),
        cwd = cwd or vim.fn.getcwd(),
        model = model or '',
    })
end

return Store
