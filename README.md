# LLMRequester

LLMRequester is a Neovim plugin that provides three main AI-powered features:

1. **Chat Interface** — for code review, refactoring suggestions, and general assistance.
2. **Code Completion** — context-aware intelligent code completions.
3. **Text Processing** — transform selected text based on AI-powered instructions.

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

- Only user and assistant messages are stored; the system prompt and editor
  context are added to requests at runtime.
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

Agent/MCP-tool functionality is not implemented yet. `:LLMRequesterAgent` and
`open_agent_window_key` currently open the regular chat and show a warning.

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
- `<leader>ai`: Open chat window (agent mode placeholder)
- `<leader>r` / `<M-CR>`: Send request
- `<leader>cx`: Stop the current request (the question is returned to the prompt)
- `<leader>q`: Close windows
- `<leader>cc`: Start a new chat (previous history is kept on disk)

### Completion

- `<C-Tab>`: Trigger completions (insert mode)
- `<Tab>`: Confirm selection

## Commands

- `:LLMRequesterChat` — Opens the chat window
- `:LLMRequesterAgent` — Opens the chat window with an agent-mode warning
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
