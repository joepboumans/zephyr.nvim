# Spec: hotkeys of the build configuration form and the Output window

Settled with Joep on 2026-10-28 after first use of the refinements. Terms are from [CONTEXT.md](../../CONTEXT.md). This replaces the keys in sections 2 and 4 of the [refinements spec](refinements.md); everything else there stands.

## Problems

1. After `:w` in `:Zephyr build edit`, you end up in insert mode again. The "needs a pristine build" question opens while the save is still running, so the picker (Telescope) and the form fight over the keys.
2. `q` closes the Output window only when the cursor is in it. The window never takes focus, so `q` usually lands in your code and starts recording a macro.
3. `<CR>` in insert mode adds a new line to the form, which breaks the `field: value` layout.
4. `<CR>` in normal mode opens the picker. `<CR>` (the same key as `<C-m>`) is awkward to reach for this.

## Keys today

| Where | Mode | Key | Does |
| --- | --- | --- | --- |
| Form | normal | `q` | close without saving |
| Form | normal | `<CR>` | open a picker for the field |
| Form | insert | `<Tab>` | complete the value, or the next item when the menu is open |
| Form | command | `:w` | save, the form stays open |
| Output window | normal | `q` | stop the running command and close |

nrf-connect.nvim and the RTT viewer define no keys.

## Keys after this change

| Where | Mode | Key | Does |
| --- | --- | --- | --- |
| Form | normal, insert | `<C-s>` | save and close |
| Form | normal | `q` | close without saving |
| Form | normal | `<Esc>` | close; with unsaved changes it warns and stays open |
| Form | insert | `<CR>` | accept, then go to the next field |
| Form | insert | `<Tab>` | complete the value, or the next item when the menu is open |
| Form | entering insert | | the menu of values for the field opens |
| Output window | normal | `q`, `<Esc>` | stop the running command and close |
| anywhere | command | `:Zephyr output close` | stop the running command and close every Output window |

### 1. `<C-s>` saves and closes the form

- `<C-s>` in normal or insert mode checks the form, saves the Build configuration and closes the form.
- Invalid input is reported as today, nothing is written, and the form stays open with the cursor where it was.
- The "needs a pristine build" question is asked after the form has closed. This fixes problem 1, so the open PR #25 is no longer needed.
- `:w` is removed: the form is a scratch buffer that cannot be written. `:w` gives Neovim's own "cannot write" error.
- The header line reads `<C-s> saves, q cancels, <Tab> completes.`

### 2. Closing the form

- `q` in normal mode closes without saving, as today.
- `<Esc>` in normal mode closes when nothing changed. With unsaved changes it stays open and says `unsaved changes: <C-s> saves, q discards`. A habitual extra `<Esc>` never loses edits.

### 3. Insert mode moves from field to field

- Entering insert mode on a field (`i`, `a`, `A`, ...) opens the completion menu with that field's values: boards, conf and overlay files, snippets, Toolchains, `true`/`false`, optimisation levels, the build directory name. Typing filters it. Fields with no values (`cmake_args`) open no menu.
- This is Neovim's insert-mode completion menu, not the `vim.ui.select` picker. A picker cannot take free text, so you could not type a board or value that is not listed.
- `<CR>` in insert mode never adds a line. It accepts the selected item when the menu is open, then moves the cursor to the end of the next field's value, still in insert mode, and opens that field's menu. On the last field it leaves insert mode instead.
- When the form opens, the cursor is on the first field's value as today, in normal mode.

### 4. The picker

The normal-mode `<CR>` picker is removed; the menu from 3 replaces it. List fields (conf files, overlays, snippets) still add the chosen item after a comma: complete again after typing `, `.

### 5. Closing the Output window

- In the Output window, `q` and `<Esc>` in normal mode stop the running command and close the window, as `q` does today.
- New command `:Zephyr output close` stops the running command and closes every window showing the Output window, from anywhere. Bind it to a key in your own config, for example:

  ```lua
  vim.keymap.set("n", "<leader>zq", "<cmd>Zephyr output close<cr>")
  ```

  zephyr.nvim sets no global keys. The RTT viewer is not an Output window; `:Zephyr rtt stop` stays the way to close it.

## Out of scope

- A redesign of the form itself (Joep will ask for that research separately).
- Default global keymaps.

## Testing

Through the public interfaces, in the existing plenary tests:

- `<C-s>` with valid input saves, closes the form and calls `on_save` after the window is gone; with invalid input nothing is saved and the form stays open.
- `:w` in the form does not save.
- `<Esc>` closes an unchanged form and keeps a changed one open.
- `<CR>` in insert mode leaves the line count unchanged and moves to the next field; on the last field it leaves insert mode.
- `:Zephyr output close` stops a running Job and closes every Output window; with none open it does nothing.
