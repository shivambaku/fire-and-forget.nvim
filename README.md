# fire-and-forget.nvim

**Fire and Forget** is a lightweight Neovim plugin for [opencode](https://github.com/sst/opencode) that runs in the background.

The repo name is `fire-and-forget.nvim`. The plugin's short runtime name stays `faf`, so you still use `require("faf")` and the `:Faf...` commands.

## Modes

| Mode       | Agent | What it does                    |
| ---------- | ----- | ------------------------------- |
| `ask`      | plan  | Questions, populates quickfix   |
| `vibe`     | build | One-shot code changes           |
| `tutorial` | plan  | Learn topics, opens as markdown |

All modes support visual selection.

## Requirements

- Neovim 0.10+
- [opencode](https://github.com/sst/opencode) CLI in PATH

## Installation

```lua
{
  "your-user/fire-and-forget.nvim",
  config = function()
    require("faf").setup()
  end,
}
```

## Configuration

```lua
require("faf").setup({
  model = nil,          -- Uses default if nil
  max_history = 50,     -- Requests to keep on disk
  keymaps = {
    input = "<leader>ii",
    list = "<leader>io",
    cancel = "<leader>ix",
  },
})
```

Set `keymaps = false` to disable all; set individual keys to `false` to disable specific ones.

## Commands

| Command      | Description         |
| ------------ | ------------------- |
| `:FafInput`  | Open input window   |
| `:FafList`   | Open request list   |
| `:FafCancel` | Cancel all requests |

## Related

- [opencode](https://github.com/sst/opencode) — The CLI tool
- [99](https://github.com/ThePrimeagen/99) — Original inspiration
