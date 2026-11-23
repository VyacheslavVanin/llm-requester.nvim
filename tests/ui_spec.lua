local api = vim.api
local Ui = require('llm-requester.chat.ui')
local Session = require('llm-requester.chat.session')

local Test = _G.Test

local session = Session.new({
    id = 'ui-session',
    cwd = vim.fn.getcwd(),
    messages = {
        { role = 'user', content = 'inspect the file' },
        {
            role = 'assistant',
            content = 'checking',
            tool_calls = {
                {
                    id = 'call_1',
                    type = 'function',
                    ['function'] = { name = 'read_file', arguments = '{"path":"a.txt"}' },
                },
            },
        },
        { role = 'tool', tool_call_id = 'call_1', name = 'read_file', content = 'line one\nline two' },
        { role = 'assistant', content = 'done' },
    },
})

Ui.setup({
    split_ratio = 0.5,
    prompt_split_ratio = 0.2,
    response_wrap = true,
    prompt_wrap = true,
    tool_folds = true,
    tool_folds_closed = true,
    show_speed = true,
}, {
    on_send = function() end,
    on_stop = function() end,
    on_close = function() end,
    on_clear = function() end,
})

Ui.open(session)
local prompt_win, response_win = Ui.windows()
local prompt_buf = api.nvim_win_get_buf(prompt_win)

Test.eq(vim.wo[response_win].wrap, true, 'response window wraps by default')
Test.eq(vim.wo[response_win].linebreak, true, 'response window breaks at word boundaries')
Test.eq(vim.wo[response_win].foldenable, true, 'tool folds are enabled')
Test.eq(vim.wo[response_win].foldmethod, 'expr', 'tool folds use an expression')
Test.eq(vim.wo[response_win].foldlevel, 0, 'tool folds start collapsed')

Test.eq(vim.bo[prompt_buf].textwidth, 0, 'prompt has no hard line length limit')
Test.eq(vim.bo[prompt_buf].wrapmargin, 0, 'prompt has no wrap margin')
Test.falsy((vim.bo[prompt_buf].formatoptions or ''):find('t', 1, true), 'prompt does not auto-wrap text')
Test.eq(vim.wo[prompt_win].wrap, true, 'prompt still soft-wraps visually')

local response_buf = api.nvim_win_get_buf(response_win)
local lines = api.nvim_buf_get_lines(response_buf, 0, -1, false)
local tool_line
for index, line in ipairs(lines) do
    if line:find('[tool]', 1, true) then
        tool_line = index
        break
    end
end

Test.truthy(tool_line, 'tool calls are rendered')
api.nvim_set_current_win(response_win)
Test.eq(Ui.fold_expr(tool_line), 1, 'tool call line starts a fold')
Test.eq(Ui.fold_expr(tool_line + 1), 1, 'tool result line is folded')
Test.eq(Ui.fold_expr(tool_line + 2), 1, 'tool output line is folded')
Test.eq(Ui.fold_expr(tool_line - 1), 0, 'the blank separator closes the previous block')

Ui.set_speed(session, { tokens_per_second = 42.5 })
Test.truthy(vim.wo[response_win].winbar:find('42.5 tok/s', 1, true), 'speed is shown in the winbar')

-- Close and reopen: reused scratch buffers must get their window options back.
Ui.close()
Ui.open(session)
local second_prompt_win, second_response_win = Ui.windows()
local second_prompt_buf = api.nvim_win_get_buf(second_prompt_win)

Test.eq(vim.wo[second_response_win].wrap, true, 'wrap is restored after reopening')
Test.eq(vim.wo[second_response_win].foldmethod, 'expr', 'folds are restored after reopening')
Test.eq(vim.bo[second_prompt_buf].textwidth, 0, 'prompt textwidth is restored after reopening')

Ui.close()
