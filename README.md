# fire-and-forget.nvim

**Fire and Forget** is a lightweight Neovim plugin for [opencode](https://github.com/sst/opencode) that runs in the background.

## Modes

| Mode       | Agent | What it does                    |
| ---------- | ----- | ------------------------------- |
| `ask`      | plan  | Questions, populates quickfix   |
| `vibe`     | build | One-shot code changes           |
| `tutorial` | plan  | Learn topics, opens as markdown |

All modes support visual selection.

In the input window, press `Ctrl-V` to attach the current clipboard image and `Ctrl-X` to remove the most recently attached image.

## Requirements

- Neovim 0.10+
- [opencode](https://github.com/sst/opencode) CLI in PATH
- For image paste support: `osascript` on macOS, `wl-paste` on Wayland, or `xclip` on X11

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
  model = nil,          -- Uses OpenCode's default model if nil
  variant = nil,        -- Uses OpenCode's default variant if nil
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

In `:FafList`, a leading `*` marks a request with a new result you have not opened yet. Press `u` to mark the selected request unread again.

## Related

- [opencode](https://github.com/sst/opencode) — The CLI tool
- [99](https://github.com/ThePrimeagen/99) — Original inspiration
