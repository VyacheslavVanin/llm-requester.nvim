# LLMRequester

LLMRequester is a Neovim plugin designed to interact with an AI language model (currently using LLaMA2) and provide feedback on code. It allows you to review, improve, and refactor code by generating suggestions in markdown format.

## Installation

To install LLMRequester, you can use your preferred package manager for Neovim.

## Usage

1. **Open LLMRequester Window**:
   - You can open the LLMRequester window by pressing `<leader>ai` (default leader is `\`). This will create a vertical split for the prompt and a horizontal split for the response.

2. **Send Request**:
   - Once you have your code in the prompt window, you can send the request to generate feedback by pressing `<leader>r`.

3. **Close Window**:
   - To close both windows, press `<leader>q` (default keymap).

## Configuration Options

You can customize LLMRequester by setting various options through the `setup` function. Here are the available configuration options:

- `model`: The AI model to use (default is `'llama2'`).
- `url`: The URL of the API endpoint for generating responses (default is `'http://localhost:11434/api/generate'`).
- `split_ratio`: The ratio of the total width that the prompt window should occupy (default is `0.6`).
- `prompt_split_ratio`: The ratio of the total height that the prompt window should occupy (default is `0.2`).
- `prompt`: The initial text to display in the prompt buffer (default is a markdown header asking for code review and refactoring suggestions).
- `open_prompt_window_key`: The keymap to open the LLMRequester window (default is `<leader>ai`).
- `request_keys`: The keymap to send the request to generate feedback (default is `<leader>r`).
- `close_keys`: The keymap to close both windows (default is `<leader>q`).
- `streaming`: Whether to handle streaming responses (default is `false`).

To set these options, you can use the following code in your Neovim configuration:

```lua
require('LLMRequester').setup({
    model = 'your-model',
    url = 'http://your-api-url',
    split_ratio = 0.7,
    prompt_split_ratio = 0.3,
    prompt = '# Code Review and Refactoring Suggestions\n',
    open_prompt_window_key = '<leader>ar',
    request_keys = '<leader>rs',
    close_keys = '<leader>cq',
})
```

## Keymaps

- `<leader>ai`: Open the LLMRequester window.
- `<leader>r`: Send the request to generate feedback.
- `<leader>q`: Close both windows.

## Commands

- `:LLMRequester`: Opens the LLMRequester window.

By following these steps, you can easily integrate LLMRequester into your Neovim setup and leverage AI-powered code review and refactoring suggestions.
