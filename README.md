# LLMRequester

LLMRequester is a Neovim plugin that provides three main AI-powered features:
1. **Chat Interface** - For code review, refactoring suggestions, and general assistance
2. **Code Completion** - Context-aware intelligent code completions
3. **Text Processing** - Transform selected text based on AI-powered instructions

The plugin supports OpenAI API backends.

## Installation

Install using your preferred Neovim package manager.

## Features

### Chat Interface
- Open a split window for chat with `<leader>ai` (default)
- Send requests with `<leader>r`
- Close windows with `<leader>q`
- Supports both streaming and non-streaming responses
- Works with OpenAI APIs

### Code Completion
- Trigger completions with `<C-Tab>` in insert mode
- Confirm selection with `<Tab>`
- Context-aware suggestions based on surrounding code

### Text Processing
- Select text in visual mode and run `:LLMRequesterProcess` to open a transformation prompt (optionally provide instructions as parameter)
- Enter instructions for how to transform the selected text
- Press Enter (`<CR>`) to confirm and send the request to the LLM
- The selected text will be replaced with the AI-generated result
- Works with OpenAI APIs

## Configuration

```lua
require('llm-requester').setup({
    chat = {
        api_type = 'openai',  -- 'openai' only
        openai_model = 'gpt-4o-mini',
        openai_url = 'https://api.openai.com/v1/chat/completions',
        api_key_file = '', -- Path to file containing the API key

        split_ratio = 0.5, -- Width ratio for prompt window
        prompt_split_ratio = 0.2, -- Height ratio for prompt window
        context_size = 16384, -- maximum context size in tokens
        prompt = 'Please review and improve this code:\n\n',
        open_prompt_window_key = '<leader>ai',
        request_keys = '<leader>r',
        close_keys = '<leader>q',
        clear_keys = '<leader>cc',
        stream = false, -- Enable streaming responses
    },
    completion = {
        api_type = 'openai', -- 'openai' only
        openai_model = 'gpt-4o-mini',
        openai_url = 'https://api.openai.com/v1/chat/completions',
        api_key_file = '', -- Path to file containing the API key
        keys = {
            trigger = '<C-Tab>',
            confirm = '<Tab>',
        },
        context_lines = 20,  -- number of lines before and after cursor position
        menu_height = 10,
        menu_width = 50,
        menu_hl = 'NormalFloat',
        menu_border = 'rounded',
    },
    processing = {
        api_type = 'openai', -- 'openai' only
        openai_model = 'gpt-4o-mini',
        openai_url = 'https://api.openai.com/v1/chat/completions',
        api_key_file = '', -- Path to file containing the API key
        keys = {
            confirm = '<CR>', -- Enter key to confirm
        },
        context_size = 16384, -- maximum context size in tokens
        menu_height = 10,
        menu_width = 50,
        menu_hl = 'NormalFloat',
        menu_border = 'rounded',
    }
})
```

## API Key Configuration

The plugin now exclusively uses file-based configuration for API keys. Set `api_key_file` to the path of a file containing your API key.

Example of file-based configuration:
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

## Keymaps

### Chat
- `<leader>ac`: Open chat window
- `<leader>ai`: Open agent chat window (can call tools)
- `<leader>r`: Send request
- `<leader>q`: Close windows
- `<leader>cc`: Clear chat and history
- `<leader>h`: Show chat history

### Completion
- `<C-Tab>`: Trigger completions (insert mode)
- `<Tab>`: Confirm selection

## Commands
- `:LLMRequesterChat`: Opens the chat window
- `:LLMRequesterAgent`: Opens the agent chat window
- `:LLMRequesterProcess`: Process selected text with AI instructions (accepts instructions as parameter)
- `:LLMRequesterSetOpenaiModel <model-name>`: Set config.openai_model

## Requirements
- Neovim 0.8+
- curl (for API requests)
- OpenAI API access
