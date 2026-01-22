local api = vim.api
local fn = vim.fn

local Completion = {}

local Utils = require('llm-requester.completion.utils')

local is_completing = false

local default_config = {
    api_type = 'openai', -- 'openai' only
    openai_model = 'gpt-4o-mini',
    openai_url = 'https://api.openai.com/v1/chat/completions',
    openai_api_key = '', -- Set your OpenAI API key here or via setup()
    keys = {
        trigger = '<C-Tab>',
        confirm = '<Tab>',
    },
    context_lines = 20,
    menu_height = 10,
    menu_width = 50,
    menu_hl = 'NormalFloat',
    menu_border = 'rounded',
}

local config = default_config -- Store config
local completion_win, completion_buf

local completion_system_message = [[
# You are an advanced AI language model designed to provide intelligent and contextually relevant assistance.

## User request format
USER'S TEXT BEFORE CURSOR<<<CURSOR>>>USER'S TEXT AFTER CURSOR

## Your reply format:
<completion>HERE YOUR COMPLETION<completion>
Do not escape html symbols inside tags.

## Task
User want you to provide completion that will be placed in <<<CURSOR>>> position.
You must replace '<<<CURSOR>>>' with your completion.

Complete whole one code block if possible: function, class, loop with body, condition with body and etc.
Your response combined with user request must form correct expressions of programming language.
No need to add additional explanations and commentaries, just completion.


## Examples
User input:
def max(a, b<<<CURSOR>>>

Assistant response:
<completion>):
    return a if a > b else b</completion>

User input:  
def calculate_sum(arr): 
    total = 0
    for num in arr:<<<CURSOR>>>
        return total

Assistant response:  
User wants calculate sum of array vlues so .... User already have ```return total```, so I will not add it to completion
<completion>
        total += num</completion>

]]

local function setup_completion_autocmd()
    vim.api.nvim_create_autocmd('BufEnter', {
        callback = function()
            local buf = vim.api.nvim_get_current_buf()
            vim.keymap.set('i', config.keys.trigger, function()
                vim.schedule(Completion.show)
                return ''
            end, { buffer = buf, expr = true, desc = "Show LLM Completion" })
        end
    })
end

function Completion.setup(user_config)
    -- Merge user config with defaults, preserving nested structure
    local merged = vim.tbl_deep_extend('force', default_config, user_config or {})
    config = merged
    setup_completion_autocmd()
end


function get_context_before(cursor)
    local line = cursor[1] - 1
    local lines = vim.api.nvim_buf_get_text(0,
        math.max(0, line - config.context_lines), 0,
        line, cursor[2],
        {}
    )
    return lines
end

function get_context_after(cursor)
    local line_count = vim.api.nvim_buf_line_count(0)
    local line = cursor[1] - 1
    local lines = vim.api.nvim_buf_get_text(0,
        line, cursor[2],
        math.min(line_count-1, line + config.context_lines), 10000,
        {}
    )
    return lines
end

-- Insert lines in current cursor position
local function insert_lines(lines)
    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor[1] - 1
    local current_col = cursor[2]

    local current_line = vim.api.nvim_get_current_line()
    local after = #current_line == current_col + 1
    vim.api.nvim_put(lines, 'c', after, true)
end

function Completion.show()
    if is_completing then
        return
    end
    is_completing = true

    local cursor = vim.api.nvim_win_get_cursor(0)
    local context_before = table.concat(get_context_before(cursor), '\n')
    local context_after = table.concat(get_context_after(cursor), '\n')
    local context = context_before .. '<<<CURSOR>>>' .. context_after

    completion_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(completion_buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(completion_buf, 'bufhidden', 'wipe')
    vim.api.nvim_buf_set_option(completion_buf, 'swapfile', false)
    vim.api.nvim_buf_set_option(completion_buf, 'undolevels', -1) -- Disable undo
    vim.api.nvim_create_autocmd('InsertEnter', {
        buffer = completion_buf,
        callback = function()
            vim.cmd('stopinsert')
        end
    })

    completion_win = vim.api.nvim_open_win(completion_buf, true, {
        relative = 'cursor',
        style = 'minimal',
        width = config.menu_width,
        height = 1, -- Start with 1 line for loading message
        row = 1,
        col = 0,
        border = config.menu_border,
        focusable = true,
        zindex = 100,
    })
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', true
    )

    vim.api.nvim_win_set_option(completion_win, 'winhl', 'Normal:' .. config.menu_hl)
    vim.api.nvim_win_set_option(completion_win, 'winblend', 10)

    local confirm = function()
        local selection = api.nvim_buf_get_lines(completion_buf, 0, -1, false)
        vim.api.nvim_win_close(completion_win, true)
        -- Insert text and restore insert mode if needed
        insert_lines(selection)
        is_completing = false
        return ''
    end
    local __default = function()
        vim.api.nvim_win_close(completion_win, true)
        is_completing = false
        return vim.api.nvim_replace_termcodes('<Ignore>', true, false, true)
    end

    -- Set key mappings in normal mode only with proper options
    api.nvim_buf_set_keymap(completion_buf, 'n', '<Esc>', '', { callback = __default })
    api.nvim_buf_set_keymap(completion_buf, 'n', config.keys.confirm, '', { callback = confirm })

    Utils.handle_openai_request(completion_system_message, context, completion_buf, completion_win, config, __default)
end

return Completion
