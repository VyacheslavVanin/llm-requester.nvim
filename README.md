# LLMRequester

LLMRequester is a Neovim plugin that provides three main AI-powered features:

1. **Chat Interface** — for code review, refactoring suggestions, and general assistance.
2. **Agent Mode** — an assistant that can read/write files and run commands with explicit permissions.
3. **Code Completion** — context-aware intelligent code completions.
4. **Text Processing** — transform selected text based on AI-powered instructions.

The plugin uses an OpenAI-compatible API and is implemented entirely in Lua. No Python runtime or background server is required.

## Installation

Install using your preferred Neovim package manager.

## Features

### Chat Interface

- Open a chat window with `<leader>ac`.
- Send requests with `<leader>r` or `<M-CR>`.
- Close windows with `<leader>q`.
- Start a fresh chat with `<leader>cc`; previous chats remain on disk.
- Supports streaming and non-streaming responses.
- Chat history is persisted to disk, so a previous conversation can be continued after restarting Neovim.
- The latest session for the current working directory is restored automatically.

### Code Completion

- Trigger completions with `<C-Tab>` in insert mode.
- Confirm selection with `<Tab>`.
- Context-aware suggestions based on surrounding code.

### Text Processing

- Select text in visual mode and run `:LLMRequesterProcess` to open a transformation prompt (optionally provide instructions as parameter).
- Enter instructions for how to transform the selected text.
- Press Enter (`<CR>`) to confirm and send the request to the LLM.
- The selected text will be replaced with the AI-generated result.

## Configuration

```lua
require('llm-requester').setup({
    chat = {
        openai_model = 'gpt-4o-mini',
        -- Accepts either a base URL or a complete /chat/completions URL:
        openai_url = 'https://api.openai.com/v1/chat/completions',
        api_key_file = '', -- Path to file containing the API key
        api_key = '',      -- Optional inline key (api_key_file takes precedence)

        temperature = 0.2,
        top_p = nil,
        stream = true,        -- Stream assistant replies token by token
        timeout = nil,        -- Overall request timeout in seconds; nil means no timeout
        connect_timeout = 15, -- Abort if the connection cannot be established
        stall_timeout = nil,  -- Abort when the provider sends no data for N seconds
        no_verify_ssl = false,
        additional_params = {}, -- Extra fields merged into the request body

        split_ratio = 0.5,
        prompt_split_ratio = 0.2,
        response_wrap = true,       -- soft-wrap the response window
        prompt_wrap = true,         -- soft-wrap the prompt (textwidth is always 0)
        tool_folds = true,          -- fold tool calls in agent chats
        tool_folds_closed = true,   -- tool blocks start collapsed
        show_speed = true,          -- generation speed of the last reply in the winbar
        open_prompt_window_key = '<leader>ac',
        open_agent_window_key = '<leader>ai',
        request_keys = '<leader>r',
        stop_keys = '<leader>cx',
        close_keys = '<leader>q',
        clear_keys = '<leader>cc',

        -- Chat history storage
        sessions_dir = vim.fn.stdpath('cache') .. '/llm-requester/sessions',
        continue_last_session = true,
        system_prompt = [[
You are a helpful and highly skilled software developer assistant.
You must help user with their task.
]],

        -- Agent mode (`:LLMRequesterAgent`, `<leader>ai`)
        agent = {
            system_prompt = [[
You are an autonomous software development assistant running inside Neovim.
You can inspect and modify files and run shell commands through the provided tools.
Prefer reading the relevant files before changing them, and keep changes focused.
]],
            tool_choice = 'auto',
            max_tool_iterations = 24,     -- request/tool rounds per user message
            iteration_limit_step = 24,    -- extra rounds offered when the limit is hit
            confirm_iteration_limit = nil, -- optional custom continuation prompt
            max_tool_calls_per_round = 20,
            max_file_bytes = 200000,
            max_write_bytes = 200000,
            max_read_lines = 2000,
            max_tool_output_bytes = 50000,
            max_stored_tool_output = 8000, -- tool output kept in the session file
            max_list_entries = 500,
            command_timeout = 60,          -- seconds
            auto_approve_limit = 20,       -- uses before asking again (outside the root)
            allow_read_visible_in_cwd = true,
            confirm = nil,                 -- optional custom approval UI
        },
    },
    completion = {
        openai_model = 'gpt-4o-mini',
        openai_url = 'https://api.openai.com/v1/chat/completions',
        api_key_file = '', -- Path to file containing the API key
        keys = {
            trigger = '<C-Tab>',
            confirm = '<Tab>',
        },
        context_lines = 20, -- number of lines before and after cursor position
        menu_height = 10,
        menu_width = 50,
        menu_hl = 'NormalFloat',
        menu_border = 'rounded',
        additional_params = {}, -- Additional parameters to pass to chat.completions API
        extended_ctx_num_files = 3, -- Number of additional files to include in the context
    },
    processing = { -- Processing config can be omitted. In this case, completion config is applied
        openai_model = 'gpt-4o-mini',
        openai_url = 'https://api.openai.com/v1/chat/completions',
        api_key_file = '', -- Path to file containing the API key
        keys = {
            confirm = '<CR>',
        },
        context_size = 16384,
        menu_height = 10,
        menu_width = 50,
        menu_hl = 'NormalFloat',
        menu_border = 'rounded',
        additional_params = {},
        extended_ctx_num_files = 3,
    },
})
```

## Chat Sessions

Each chat session is stored as a separate JSON file in `sessions_dir`
(`stdpath('cache')/llm-requester/sessions` by default).

- Only user/assistant messages (and, in agent sessions, tool calls and their
  results) are stored; the system prompt and editor context are added to
  requests at runtime.
- API keys are never written to session files.
- `clear_keys` / `:LLMRequesterChatNew` starts a new session and keeps the old
  one available on disk.
- `<leader>cx` / `:LLMRequesterChatStop` stops the current request, discards the
  partial reply and returns the question to the prompt for editing or resending.
- `:LLMRequesterChatSessions` lets you pick a previously saved session.
- On startup, the latest non-empty session for the current working directory is
  loaded automatically when `continue_last_session` is enabled.

### Request timeouts and stopping

- `<leader>cx` / `:LLMRequesterChatStop` immediately kills the active `curl`
  process, discards the partial reply and returns the question to the prompt.
- `connect_timeout` (default `15`) limits connection establishment.
- `stall_timeout` (default `nil`) aborts the request if the provider stops
  sending data for the configured number of seconds.
- `timeout` (default `nil`) is an overall request deadline.

## Agent Mode

`:LLMRequesterAgent` (`<leader>ai`) opens an agent session bound to the current
working directory. Agent mode uses OpenAI-compatible function calling, so the
provider must support `tools` / `tool_calls`.

Every session records its mode (`chat` or `agent`) and the agent session is
bound to its root directory. The agent cannot change that directory; relative
tool paths are resolved against it.

### Tools

| Tool | Purpose |
| --- | --- |
| `read_file` | Read a text file with line numbers, optional `start_line` / `max_lines`. |
| `write_file` | Create or overwrite a file. Parent directories must exist. |
| `list_directory` | List directory entries. Hidden entries are omitted unless requested. |
| `run_command` | Run a command with `sh -c` in the session root (timeout, captured output). |

### Permissions

| Operation | Default |
| --- | --- |
| Read a visible file inside the root | Allowed without asking |
| Read a hidden file or a path outside the root | Confirmation required |
| List a visible directory inside the root | Allowed without asking |
| List hidden entries or a directory outside the root | Confirmation required |
| Write any file | Confirmation required (unless a grant exists) |
| Run any command | Confirmation required (unless a rule exists) |

Approval prompts offer:

- **Allow once** — no grant is stored.
- **Allow this file / directory for the session** — for file operations.
- **Allow this exact command / all commands starting with the first word** — for
  commands, with a limited number of uses.
- **Deny** (or pressing `Esc`).

Grants for files and directories **inside the root are unlimited for the
session**. Grants for paths **outside the root** and all command rules expire
after `auto_approve_limit` uses and then prompt again. Every tool round is also
bounded by `max_tool_iterations` / `max_tool_calls_per_round`, and commands are
bounded by `command_timeout`, so a loop cannot hang Neovim.

When `max_tool_iterations` is reached the agent asks whether to continue with
`iteration_limit_step` more rounds or to stop. Stopping is not an error: the
unfinished tool calls are recorded as skipped and the conversation stays usable.
The limit is reset for every new user message.

Paths are canonicalized with symlinks resolved; broken symlinks are rejected.
A directory grant only covers real descendants (a grant for `src` never covers
`src-other`).

### Sessions and stopping

- Tool calls and their results are stored in the session file, so an agent
  conversation can be resumed after restarting Neovim.
- Tool output stored on disk is truncated to `max_stored_tool_output`.
- `<leader>cx` / `:LLMRequesterChatStop` kills the active request (including a
  running command), rolls back the unfinished exchange and returns the question
  to the prompt.
- Agent and chat histories are separate: `:LLMRequesterAgent` restores the
  latest agent session for the directory, while `:LLMRequesterChat` restores the
  latest chat session.

### Tool folds and speed

- Each tool call and its output form a fold (`[tool]` / `[result]` / `[out]`
  lines). Folds start collapsed; toggle with `za`, open all with `zR`.
  Set `tool_folds_closed = false` to start expanded, or `tool_folds = false`
  to disable folding.
- The response winbar shows cumulative token usage and the generation speed of
  the last reply: approximate characters per second while streaming and
  `tok/s` once the provider reports usage. Set `show_speed = false` to hide it.

## API Key Configuration

The plugin uses file-based configuration for API keys by default. Set
`api_key_file` to the path of a file containing your API key:

```lua
require('llm-requester').setup({
    chat = {
        api_key_file = '/path/to/your/api-key-file.txt',
        -- other chat options...
    },
    completion = {
        api_key_file = '/path/to/your/api-key-file.txt',
        -- other completion options...
    }
})
```

For chat, `LLM_API_KEY` from the environment is used when neither `api_key`
nor `api_key_file` is configured.

## Keymaps

### Chat

- `<leader>ac`: Open chat window
- `<leader>ai`: Open agent chat window
- `<leader>r` / `<M-CR>`: Send request
- `<leader>cx`: Stop the current request (the question is returned to the prompt)
- `<leader>q`: Close windows
- `<leader>cc`: Start a new chat (previous history is kept on disk)

### Completion

- `<C-Tab>`: Trigger completions (insert mode)
- `<Tab>`: Confirm selection

## Commands

- `:LLMRequesterChat` — Opens the chat window
- `:LLMRequesterAgent` — Opens an agent chat window (files, directories, commands)
- `:LLMRequesterChatNew` — Starts a new chat session
- `:LLMRequesterChatStop` — Stops the current request and returns the question to the prompt
- `:LLMRequesterChatSessions` — Selects a saved chat session
- `:LLMRequesterProcess` — Processes selected text with AI instructions (accepts instructions as parameter)
- `:LLMRequesterCompletion` — Shows an LLM completion at the cursor
- `:LLMRequesterSetOpenaiModel <model-name>` — Sets the chat model

## Requirements

- Neovim 0.10+
- curl (for API requests)
- OpenAI-compatible API access

## Tests

Run the headless test suite from the repository root:

```bash
nvim --headless -u NONE -c "set rtp+=." -c "luafile tests/run.lua"
```
