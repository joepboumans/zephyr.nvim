# Spec: closing the Output window

Settled with Joep on 2026-10-28. Terms are from [CONTEXT.md](../../CONTEXT.md). This replaces the keys of the Output window in section 4 of the [refinements spec](refinements.md); everything else there stands.

The keys of the build configuration form are not part of this spec. The form is being replaced by the panel from the [build configuration UI research](../research/build-config-ui.md), and its keys are specified with it. Joep's choices for them: `<C-s>` saves and closes, `:w` does not save, `q` and `<Esc>` close.

## Problem

`q` closes the Output window only when the cursor is in it. The window never takes focus, so `q` usually lands in your code and starts recording a macro.

## Keys today

| Where | Mode | Key | Does |
| --- | --- | --- | --- |
| Output window | normal | `q` | stop the running command and close |

nrf-connect.nvim and the RTT viewer define no keys.

## Keys after this change

| Where | Mode | Key | Does |
| --- | --- | --- | --- |
| Output window | normal | `q`, `<Esc>` | stop the running command and close |
| anywhere | command | `:Zephyr output close` | stop the running command and close every Output window |

- In the Output window, `q` and `<Esc>` in normal mode stop the running command and close the window, as `q` does today.
- New command `:Zephyr output close` stops the running command and closes every window showing the Output window, from anywhere. With none open it does nothing. Bind it to a key in your own config, for example:

  ```lua
  vim.keymap.set("n", "<leader>zq", "<cmd>Zephyr output close<cr>")
  ```

  zephyr.nvim sets no global keys. The RTT viewer is not an Output window; `:Zephyr rtt stop` stays the way to close it.

## Testing

Through the public interfaces, in the existing plenary tests:

- `<Esc>` in the Output window stops a running Job and closes the window, like `q`.
- `:Zephyr output close` stops a running Job and closes every Output window; with none open it does nothing.
