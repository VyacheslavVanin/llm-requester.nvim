-- Persistent history of text-processing prompts.
--
-- Prompts are stored newest-first in a small JSON file. The list is global for
-- the user, deduplicated and limited. Writes go through a temporary file and an
-- atomic rename, so a crash cannot leave a half-written history behind.

local uv = vim.uv or vim.loop

local History = {}
History.__index = History

local function trim(text)
    return tostring(text or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function normalize_limit(value)
    local limit = tonumber(value)
    if not limit or limit < 1 then
        return 50
    end
    return math.floor(limit)
end

function History.new(options)
    options = options or {}

    return setmetatable({
        path = options.path or (vim.fn.stdpath('cache') .. '/llm-requester/processing_history.json'),
        limit = normalize_limit(options.limit),
        prompts = {},
    }, History)
end

---Loads the history from disk. Corrupt files are treated as empty history.
---@return string[] prompts
---@return string|nil err
function History:load()
    self.prompts = {}

    if self.path == '' or vim.fn.filereadable(self.path) ~= 1 then
        return self.prompts
    end

    local read_ok, lines = pcall(vim.fn.readfile, self.path)
    if not read_ok then
        return self.prompts, tostring(lines)
    end

    local decode_ok, decoded = pcall(vim.json.decode, table.concat(lines, '\n'))
    if not decode_ok or type(decoded) ~= 'table' then
        return self.prompts, 'invalid processing history file: ' .. self.path
    end

    local values = decoded.prompts or decoded
    if type(values) ~= 'table' then
        return self.prompts, 'invalid processing history format: ' .. self.path
    end

    local seen = {}
    for _, value in ipairs(values) do
        local prompt = trim(value)
        if prompt ~= '' and not seen[prompt] then
            seen[prompt] = true
            table.insert(self.prompts, prompt)
            if #self.prompts >= self.limit then
                break
            end
        end
    end

    return self.prompts
end

---Returns a copy of the stored prompts (newest first).
---@return string[]
function History:entries()
    return vim.deepcopy(self.prompts)
end

---Adds a prompt to the front, moving duplicates to the front and trimming the
---list to the configured limit.
---@param prompt string
---@return boolean ok
---@return string|nil err
function History:add(prompt)
    local value = trim(prompt)
    if value == '' then
        return true
    end

    for index, existing in ipairs(self.prompts) do
        if existing == value then
            table.remove(self.prompts, index)
            break
        end
    end

    table.insert(self.prompts, 1, value)
    while #self.prompts > self.limit do
        table.remove(self.prompts)
    end

    return self:save()
end

function History:save()
    if self.path == '' then
        return true
    end

    local dir = vim.fn.fnamemodify(self.path, ':h')
    local mkdir_ok, mkdir_err = pcall(vim.fn.mkdir, dir, 'p')
    if not mkdir_ok then
        return false, tostring(mkdir_err)
    end

    local encoded_ok, encoded = pcall(vim.json.encode, {
        version = 1,
        prompts = self.prompts,
    })
    if not encoded_ok then
        return false, tostring(encoded)
    end

    local temporary_path = self.path .. '.tmp'
    local write_ok, write_err = pcall(vim.fn.writefile, { encoded }, temporary_path)
    if not write_ok then
        return false, tostring(write_err)
    end

    local renamed, rename_err = uv.fs_rename(temporary_path, self.path)
    if not renamed then
        os.remove(temporary_path)
        return false, tostring(rename_err)
    end

    return true
end

---Pure ring index for the prompt window.
--
-- 0 is the draft; 1 is the newest prompt; `count` is the oldest. Moving to an
-- older prompt from the oldest wraps to the newest, and moving to a newer one
-- from the newest restores the draft.
---@param current integer
---@param count integer
---@param direction "older"|"newer"
---@return integer
function History.cycle_index(current, count, direction)
    if count <= 0 then
        return 0
    end

    if direction == 'older' then
        if current <= 0 then
            return 1
        end
        if current >= count then
            return 1
        end
        return current + 1
    end

    if current <= 0 then
        return count
    end
    if current == 1 then
        return 0
    end
    return current - 1
end

return History
