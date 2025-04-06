local api = vim.api
local fn = vim.fn

local Completion = {}

local is_completing = false

local default_config = {
    api_type = 'ollama', -- 'ollama' or 'openai'
    ollama_model = 'llama2',
    ollama_url = 'http://localhost:11434/api/chat',
    openai_model = 'llama2',
    openai_url = 'https://openrouter.ai/api/v1/chat/completions',
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
**System Prompt:**
You are Mr.Completer - an expert AI code assistant specializing in precise, context-aware code completion.
Your task is to analyze the provided code snippet (including prior lines and the incomplete current line)
and generate the *best possible continuation* that:

0. Your completion will be directly concatinated to user providced code
1. **Completes *only* the current function, class, or structural block**—do not write unrelated code.
2. **Matches the implied intent** of the user’s partial code (infer patterns, style, and purpose).
3. **Produces production-grade quality**:
   - Clean, efficient, and maintainable (like a senior developer with 10+ years of experience).
   - Follows language/framework best practices (e.g., PEP 8 for Python, SOLID principles).
   - Handles edge cases gracefully (e.g., null checks, validation).
4. **Prioritizes correctness**: Ensure the completion compiles/runs without errors.
5. **Preserves context**: Maintain variable names, libraries, and idioms from the snippet.

**Response Rules**:
- Output *only* the completion to provided code (no explanations or notes).
- Never repeat the user's provided code—just append the completion.
- If the intent is unclear, complete with a *generic, reusable* implementation.
- NEVER enclose a completion in markdown code block, insert only raw text

**Example**:  
User Input (Python):  
    def calculate_stats(data):  
        mean = sum(data) / len(data)  
        variance = sum((x - mean) ** 2  
Assistant Output:  
for x in data) / len(data)  
        return {"mean": mean, "variance": variance}  

**Example**:  
User Input (c++):  
    struct Vector3d {
Assistant Output:  
        float x;
        float y;
        float z;
    };
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

function Completion.show()
    if is_completing then
        return
    end
    is_completing = true

    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = cursor[1] - 1
    local lines = vim.api.nvim_buf_get_text(0,
        math.max(0, line - config.context_lines), 0,
        line, cursor[2],
        {}
    )
    local context = table.concat(lines, '\n')

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

    -- Setup key mappings before API call
    local keys = {
        [config.keys.confirm] = function()
            local selection = api.nvim_buf_get_lines(completion_buf, 0, -1, false)
            vim.api.nvim_win_close(completion_win, true)
            -- Insert text and restore insert mode if needed
            local row, col = unpack(vim.api.nvim_win_get_cursor(0))
            vim.api.nvim_put(selection, 'c', true, true)
            is_completing = false
            return ''
        end,
        __default = function()
            vim.api.nvim_win_close(completion_win, true)
            is_completing = false
            return vim.api.nvim_replace_termcodes('<Ignore>', true, false, true)
        end,
    }

    -- Set key mappings in normal mode only with proper options
    api.nvim_buf_set_keymap(completion_buf, 'n', '<Esc>', '', { callback = keys.__default })
    api.nvim_buf_set_keymap(completion_buf, 'n', config.keys.confirm, '', { callback = keys[config.keys.confirm] })

    local function handle_openai_request()
        local json_data = vim.json.encode({
            model = config.openai_model,
            messages = {
                {
                    role = "system",
                    content = completion_system_message
                },
                {
                    role = "user",
                    content = context
                }
            },
            stream = false,
            temperature = 0.2,
            max_tokens = config.context_size
        })

        local headers = {
            'Authorization: Bearer ' .. config.openai_api_key,
            'Content-Type: application/json'
        }

        fn.jobstart({'curl', '-s', '-X', 'POST', config.openai_url, '-H', headers[1], '-H', headers[2], '-d', json_data}, {
            on_stdout = function(_, data)
                local response = table.concat(data, '')
                local ok, result = pcall(vim.json.decode, response)
                if ok and result.choices and result.choices[1] and result.choices[1].message then
                    local suggestions = {}
                    for line in vim.gsplit(result.choices[1].message.content, '\n') do
                        if line ~= '' then
                            table.insert(suggestions, line)
                        end
                    end
                    vim.schedule(function()
                        if vim.api.nvim_win_is_valid(completion_win) then
                            vim.api.nvim_buf_set_lines(completion_buf, 0, -1, false, suggestions)
                            vim.api.nvim_win_set_height(completion_win,
                                math.min(#suggestions, config.menu_height))
                            api.nvim_buf_set_option(completion_buf, 'modifiable', false)
                        end
                    end)
                end
            end,
            on_exit = function(_, code)
                if code ~= 0 then
                    vim.schedule(function()
                        if vim.api.nvim_win_is_valid(completion_win) then
                            vim.api.nvim_buf_set_lines(completion_buf, 0, -1, false,
                                {'Error getting completions'})
                            api.nvim_buf_set_option(completion_buf, 'modifiable', false)
                        end
                    end)
                end
            end
        })
    end

    local function handle_ollama_request()
        local json_data = vim.json.encode({
            model = config.ollama_model,
            messages = {
                {
                    role = "system",
                    content = completion_system_message
                },
                {
                    role = "user",
                    content = context
                }
            },
            stream = false,
            options = {
                temperature = 0.2,
                num_ctx = config.context_size
            }
        })

        fn.jobstart({'curl', '-s', '-X', 'POST', config.ollama_url, '-d', json_data}, {
            on_stdout = function(_, data)
                local response = table.concat(data, '')
                local ok, result = pcall(vim.json.decode, response)
                if ok and result.message and result.message.content then
                    local suggestions = {}
                    for line in vim.gsplit(result.message.content, '\n') do
                        if line ~= '' then
                            table.insert(suggestions, line)
                        end
                    end
                    vim.schedule(function()
                        if vim.api.nvim_win_is_valid(completion_win) then
                            vim.api.nvim_buf_set_lines(completion_buf, 0, -1, false, suggestions)
                            vim.api.nvim_win_set_height(completion_win,
                                math.min(#suggestions, config.menu_height))
                            api.nvim_buf_set_option(completion_buf, 'modifiable', false)
                        end
                    end)
                end
            end,
            on_exit = function(_, code)
                if code ~= 0 then
                    vim.schedule(function()
                        if vim.api.nvim_win_is_valid(completion_win) then
                            vim.api.nvim_buf_set_lines(completion_buf, 0, -1, false,
                                {'Error getting completions'})
                            api.nvim_buf_set_option(completion_buf, 'modifiable', false)
                        end
                    end)
                end
            end
        })
    end

    if config.api_type == 'openai' then
        handle_openai_request()
    else
        handle_ollama_request()
    end
end

return Completion
