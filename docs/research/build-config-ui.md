# Build configuration UI: what should replace the `field: value` buffer?

Researched 2026-10-28 for `:Zephyr build new` / `:Zephyr build edit`
(spec: [`docs/specs/refinements.md` §2](../specs/refinements.md), code:
[`lua/zephyr/ui/build_form.lua`](../../lua/zephyr/ui/build_form.lua)).
Constraint: no runtime dependencies; `vim.ui.select` / `vim.ui.input` are fine
because the user's picker (telescope, fzf-lua, snacks, dressing) overrides them.

## 1. Question and TL;DR

**Question:** what is the best no-dependency Neovim UI to create and edit a
Build configuration?

**TL;DR:** Replace the editable buffer with a **read-only settings panel**
(Option B): a float with one labelled row per field, rendered by the plugin like
lazy.nvim's and mason.nvim's windows. `<CR>` on a row changes that field through
`vim.ui.select` (board, files, snippets, optimization, Toolchain) or
`vim.ui.input` (build dir, CMake args), booleans toggle in place, `s` (and `:w`)
saves, `q`/`<Esc>` closes. For `new`, the same panel opens and pops the board
picker at once, because board is the only field without a default. That gives
you the wizard's guided start without a separate wizard.

## 2. How the current form works, and why it feels like "a buffer with random fields"

`build_form.open` creates an `acwrite` scratch buffer in a float, writes
`settings.fields` as raw `name: value` lines (`render`, l.37–65) and **parses
the text back** on `:w` (`parse`, l.81–124). `<CR>` runs `vim.ui.select` and
rewrites the line (l.258–277), `<Tab>` in insert mode calls `vim.fn.complete`
(l.228–256), and `q` closes (l.373).

Why it reads as "random fields":

- **The keys are the storage names.** You see `extra_conf_files:` and
  `cmake_args:`, not "Extra Kconfig fragments" or "CMake arguments", and nothing
  shows which values are defaults, which are required, or what each field does.
  There are two `#` comment lines of syntax rules at the top instead.
- **You can type anything anywhere.** You can delete a key, break the colon,
  duplicate a field or type `sysbuild: maybe`. `parse` has to report all of
  these (l.86–91, 112). Most of the 397 lines handle text the user should never
  have been able to produce.
- **Modes fight each other.** You edit in insert mode, but `<CR>` (picker) and
  `q` (close) are normal-mode maps. In insert mode `<CR>` inserts a line, and
  `q` in normal mode shadows macro recording. Every key change has to answer
  "what does this key do in a text buffer?"
- **Lists are free text with separators** (`, `, or spaces for `cmake_args`,
  l.19–22), so choosing a list item is string surgery (`set_value`, l.214–226).

The pattern the form copies, oil.nvim, works because its domain *is* text (file
names), so editing those names with Vim motions is the feature. Build settings
are mostly **choices from a known set** (board, files found in the App, enums,
booleans). For those, a picker beats text editing.

## 3. Survey

### Neovim built-ins

- **`vim.ui.select(items, opts, on_choice)`** is "the standard picker interface".
  Plugins may override it and should honour `format_item` and the `kind` hint
  ([lua.txt `vim.ui.select()`][nv-luatxt]). The **default** implementation is
  `vim.fn.inputlist`, a numbered list on the command line
  ([`runtime/lua/vim/ui.lua` L63–80][nv-ui-select]). That works for 5 enum
  values but not for hundreds of boards, so the plugin should not depend on a
  good picker being installed for small choices. Real pickers replace it:
  snacks `ui_select = true` ([snacks picker.md L149][snacks-picker]), fzf-lua
  `register_ui_select` ([README][fzf-readme]) and telescope-ui-select
  ([README][tele-uiselect]).
- **`vim.ui.input(opts, on_confirm)`** takes `prompt`, `default` and
  `completion` (any `:command-completion` type), and passes `nil` on cancel
  ([lua.txt `vim.ui.input()`][nv-luatxt]; default impl: `vim.fn.input` with
  `cancelreturn`, [ui.lua L126–145][nv-ui-input]). `completion` accepts
  `customlist,{func}` ([map.txt L1450][nv-maptxt]), and Lua functions can be
  named through `v:lua.require'mod'.fn` ([lua.txt `v:lua-call`][nv-vlua]). So
  `vim.ui.input` can offer board or file completion. `customlist,v:lua…` in
  `input()` is not documented explicitly: verify it before relying on it.
  snacks.input also accepts `completion` ([snacks input.md][snacks-input]).
- **Floats:** `nvim_open_win` takes `title` and `footer` (+ `_pos`), and footer
  has existed since 0.10 ([api.txt `nvim_open_win()`][nv-apitxt];
  [news-0.10][nv-news10]). The footer is a natural home for the key hints.
- **Extmarks:** `virt_text_pos` = `eol`, `eol_right_align`, `overlay`,
  `right_align` or `inline` ([api.txt `nvim_buf_set_extmark()`][nv-apitxt]).
  Inline virtual text arrived in 0.10 ([news-0.10][nv-news10]). This lets you
  dim "(default)" or "(from board)" hints without putting them in the text.
- **`buftype=prompt`** makes only the last line editable and submits on Enter.
  It is meant for chat, REPL and picker UIs ([channel.txt `prompt-buffer`][nv-prompt]).
  nui.nvim's `Input` and snacks.input are built on it
  ([nui input L50, L117][nui-input]; [snacks input.lua][snacks-input-src]).
  It suits a single input, not a multi-field form.
- **`acwrite` + `'nomodifiable'`:** `acwrite` buffers are always written through
  `BufWriteCmd` ([options.txt `'buftype'`][nv-optstxt]). A non-modifiable
  `acwrite` buffer can therefore still honour `:w` as "save" without accepting
  typed text.

### cmake-tools.nvim (Civitasv): one picker per setting, plus a raw settings buffer

- Each setting has its own command that runs a single `vim.ui.select`: build type
  ([init.lua L725–760][cmt-buildtype]), kit (L770), configure/build/test preset
  (L816/L915/L866), build and launch target (L984/L1048). `generate` **chains**
  into `select_configure_preset` when nothing is chosen yet
  ([init.lua L86–155][cmt-generate]). That is a lazy wizard: it asks only for
  what is missing.
- Free values (cwd, build dir) use `vim.ui.input` with `default` and
  `completion = "dir"` ([init.lua L1612–1660][cmt-input]).
- `:CMakeSettings` / target settings open a float with an `acwrite` buffer that
  holds a Lua table (`vim.inspect`) and maps `q`/`<Esc>` to close and
  `BufWriteCmd` to save ([init.lua L1150–1185][cmt-settings];
  [window.lua L84–100][cmt-window]). This is the same "editable text" approach
  as ours, kept for the rarely used free-form part.

### lazy.nvim: a rendered, read-only float with per-row keys

- The float buffer is `readonly` and `nomodifiable` ([float.lua L118–127][lazy-float]),
  and keys are bound with `nowait` per buffer (`on_key`, L255–260).
- `<CR>` = details, `q` = close and `K`, `]]`, `[[` as defined in one table
  ([view/config.lua L29–39][lazy-keys]). The renderer keeps a row→plugin
  `locations` map so a key acts on the item under the cursor
  ([render.lua L19, L103–110][lazy-render]).
- Numeric settings are edited with `vim.ui.input` from inside the panel (profile
  threshold, [view/init.lua L144–160][lazy-input]).

### mason.nvim: the same pattern, with keybinds per line

- The renderer toggles `modifiable` only around `nvim_buf_set_lines`, uses
  extmark virtual text, and registers keybinds **per line**
  (`registered_keybinds[line][key]`) ([display.lua L304–382][mason-display]).
- Single-letter actions are configurable (`<CR>` expand, `i` install, `u` update,
  `X` uninstall) ([settings.lua L151–181][mason-keys]). Filters use
  `vim.ui.select` with a `kind` ([instance.lua L505–515][mason-filter]).

### oil.nvim: the editable buffer done well

- Its README pitch is "edit your filesystem like a normal Neovim buffer… `:w`
  when you're done" ([README L3, L134][oil-readme]).
- What makes it work: (1) the text is the data (names), (2) hidden IDs are
  concealed (`conceallevel = 3`, [config.lua L26–27][oil-config]), (3) the cursor
  is constrained to editable columns (`constrain_cursor = "editable"`, config
  L51; [view.lua L292][oil-view]), and (4) `:w` shows a **confirmation of the
  computed actions** before applying them ([mutator/init.lua L500, L572][oil-mutator]).
- We have none of (2)–(4), and (1) doesn't hold for us.

### Neogit / fugitive: status buffers and option popups

- Neogit buffers are `readonly` + `nomodifiable` ([buffer.lua L73–74][neogit-buf]).
  Its popups (transient-style) list switches and options. Setting an option
  picks from `choices` with a fuzzy finder or asks with `get_user_input`, and
  pressing it again clears the value ([popup/init.lua L183–205][neogit-popup]).
  This is the closest analogue to a "settings panel": every row is a setting,
  one key changes it and the value shows inline.
- fugitive's status buffer is `readonly nomodifiable` with one-key actions per
  line (`s`, `-`, `=`, `<CR>`) ([fugitive.txt L286–354][fug-doc]).

### Form libraries (reference only, they are dependencies)

- nui.nvim ships Popup/Input/Menu/Layout but no Form ([README][nui-readme]).
  Forms with validation live in a second dependency, nui-components.nvim
  ([README][nuicomp-readme]). We would need two runtime dependencies to get a
  widget form, so this is ruled out.

### Embedded wizard: nvim-platformio.lua

- `:Pioinit` is a pure picker chain: board → framework → `pio project init`
  ([pioinit.lua L22–35][pio-init]). The picker backend can be `ui_select`
  ([README L69][pio-readme]). It works because a PlatformIO init has two
  choices. I found no Zephyr, ESP-IDF or Rust plugin with a richer config wizard.

### VS Code nRF Connect "Add build configuration" (UX target)

From Nordic's docs ([configure and build sample][nrf-bm-rst]): a single page
with SDK and Toolchain menus, a **Board target** drop-down, **Base configuration
files** and **Extra Kconfig fragments** drop-downs, and "other options: leave at
their defaults". It ends in one primary **Generate and Build** button. **Extra
CMake arguments** is a list where each entry has a remove (×) on hover
([DevZone 110115][devzone-cmake]), and sysbuild is a selection on the same
screen ([release notes 2024.9.31][nrf-rn]). In short: **one screen, labelled
rows, choices as drop-downs, defaults pre-filled, only the board required**. The
full field reference page renders client-side and could not be fetched, so the
exact order of the remaining fields is unverified.

## 4. Options for zephyr.nvim

Today `build_form.lua` is 397 lines. Of those, `render` + `parse` + `complete`
+ `set_value` (~170 lines) exist only because the UI is free text. Candidate
discovery (`files_in`, `snippets`, `toolchains`, `candidates`, ~80 lines) and
`save` (~30 lines) stay in every option.

### A. Keep the editable buffer, polish it

Labels as inline/overlay extmarks, values concealed or constrained like oil,
hints as `eol` virtual text, `<Tab>`/`<CR>` in insert mode moving to the next
field.

- **Pros:** smallest diff and familiar to oil users. Free text stays fast for
  `cmake_args`.
- **Cons:** keeps `parse`, adds cursor-constraint code like oil's (oil needs
  ~150 lines of `calc_constrained_cursor_pos` plus autocmds), and still has two
  modes with different keys. Every new key needs an insert-mode story. Lists stay
  separator strings.
- **Pickers:** only `<CR>` uses them, the same as today.
- **Tests:** via feedkeys into a text buffer, the same as today, and still
  timing-sensitive for `<Tab>` (spec uses `vim.wait(50)`).
- **Size:** about 397 → 450 lines. **Keys:** the insert/normal split stays and
  `q` still conflicts with macro recording.

### B. Read-only settings panel (lazy/mason/neogit-popup style)

A `nomodifiable` `acwrite` float. One row per field reads "Label  value
(hint)". `<CR>` (or `e`) edits the row under the cursor: enums, board, files,
snippets and Toolchain go through `vim.ui.select`; `build_dir`, `cmake_args`
and `board_roots` through `vim.ui.input` with `default` = current value;
booleans toggle. `x` resets a row to its default. `s` or `:w` saves, `q`/`<Esc>`
closes (asking if there are unsaved changes).

- **Pros:** state lives in a Lua table, not text, so `parse`, `complete` and
  `set_value` go away and invalid input becomes impossible by construction. It
  is a well-established pattern (lazy, mason, neogit, fugitive). It has one
  mode, so `q`, `<CR>` and `:w` all mean one thing, and nothing to type can
  break. Labels and default hints come for free in the renderer.
- **Cons:** typing a long `cmake_args` line happens in a one-line input instead
  of a buffer, which is fine for a handful of `-D` flags. List fields need a
  multi-pick story because `vim.ui.select` picks one item (see §5).
- **Pickers:** every change goes through `vim.ui.select`/`input`, so
  telescope/fzf/snacks users get their own UI everywhere, with fuzzy board
  search. Passing `kind = "zephyr.board"` etc. lets them special-case it.
- **Tests:** stub `vim.ui.select`/`input` (the spec already does, L129–132),
  move the cursor, feed `<CR>`/`s`, and assert on `build_config`. No
  `vim.wait` for completion menus.
- **Size:** about 397 → 280–320 lines (render ~40, field editors ~60, keys ~25,
  minus ~170 of text handling).
- **Keys:** normal mode only and `nowait`, like lazy (`q`, `<CR>`) and mason
  (`i`, `X`). `q` shadowing macro recording is accepted practice in read-only
  panels: lazy, mason, cmake-tools and fugitive all bind it.

### C. Pure wizard (chained `vim.ui.select`/`input`)

board → conf files → extra conf → overlays → snippets → sysbuild → optimization
→ board roots → cmake args → Toolchain → build dir.

- **Pros:** no window code at all, and it feels native with any picker
  (nvim-platformio does this).
- **Cons:** 11 prompts where VS Code says "leave the rest at defaults". There
  is no overview, no back step, and Esc halfway loses everything. It is useless
  for `edit` (you'd walk all 11 to change one), and with the default
  `inputlist` picker it is painful.
- **Tests:** easy, because you queue stubbed answers.
- **Size:** ~200 lines, but it only covers `new`. **Keys:** none.

### D. Hybrid: wizard for `new`, panel for `edit`

- **Pros:** guided creation and a fast edit.
- **Cons:** you build and test both B *and* C, and the two UIs diverge. The
  wizard still asks about fields most people leave at defaults.
- **Size:** B + ~80 lines.

### Comparison

| | A polish buffer | **B panel** | C wizard | D hybrid |
|---|---|---|---|---|
| Invalid input possible | yes | **no** | no | no |
| Overview of all settings | yes | **yes** | no | edit only |
| Uses user's picker | `<CR>` only | **every edit** | every step | every step |
| Mode/key conflicts | many | **none** | none | none |
| Approx. lines | ~450 | **~300** | ~200 (new only) | ~380 |

## 5. Recommendation

**Option B, with one wizard-like touch.** `:Zephyr build new` opens the panel
pre-filled with defaults and immediately runs the board picker; cancelling
leaves you in the panel with an empty board. Saving without a board is refused
on that row. That matches the VS Code flow (board required, rest defaulted,
one screen) and the cmake-tools "ask only for what's missing" chaining. It is
also the smallest code that removes the whole class of text-editing bugs
(KISS/YAGNI), and it is the same UI for `new` and `edit`.

Sketch (title and footer via `nvim_open_win`; dim parts are virtual text):

```
╭───────────── New build configuration · blinky ─────────────╮
│ Board target        nrf52840dk/nrf52840                    │
│ Build directory     build_nrf52840dk         (from board)  │
│ Kconfig files       —                        (prj.conf)    │
│ Extra Kconfig       debug.conf                             │
│ DT overlays         app.overlay                            │
│ Snippets            —                                      │
│ Sysbuild            ✓ on                                   │
│ Optimization        default                                │
│ Board roots         —                                      │
│ CMake arguments     -DCONFIG_FOO=y                         │
│ Toolchain           zephyr-sdk 0.17.0        (default)     │
╰─ <CR> change · x reset · s save · q close · g? help ───────╯
```

Per-field behaviour on `<CR>`:

- **board, optimization, Toolchain:** `vim.ui.select` (single choice).
  "Still listing boards" stays as now.
- **sysbuild:** toggles in place.
- **conf/extra conf/overlays/snippets:** `vim.ui.select` over candidates shown as
  `✓ debug.conf` / `  prj.conf`. Picking one toggles it and reopens the picker,
  with a final `Done` item. This works with every picker and needs no
  multi-select API.
- **build_dir, cmake_args, board_roots:** `vim.ui.input` with `default` = current
  text (space separated for cmake args), `completion = "dir"` for board roots.
- **save:** `s` and `:w` (`BufWriteCmd`) both call the existing `save` with the
  same `build_config.validate`. Put errors on the offending row with
  `vim.diagnostic` or an `eol` extmark, not only in `notify`.

Open questions for Joep:

1. **List fields:** is the "toggle and re-open the picker until Done" flow
   acceptable, or would you rather list items be their own rows (`a` add / `x`
   remove under the cursor, like VS Code's × per CMake arg)?
2. **Labels:** should they live as a `label` on `settings.fields`, which keeps
   one field list (DRY), or in the UI module? `settings` is a storage module.
3. **Keep `:w`?** It costs one autocmd and keeps muscle memory. Do you want `s`
   as well, or only `:w`?
4. **Build after save?** VS Code's primary button is "Generate and Build".
   Should `new` offer to build right after saving (one `vim.ui.select`, like the
   existing Pristine prompt)?
5. **`q` with unsaved changes:** ask Save / Discard / Cancel, or discard
   silently as today?

## 6. Sources

Commit SHAs pinned on 2026-10-28.

- https://github.com/neovim/neovim/blob/61e71ccf8aa17a2fb6fe5caa115daf21a0b3e9fa/runtime/doc/lua.txt#L5650-L5760
- https://github.com/neovim/neovim/blob/61e71ccf8aa17a2fb6fe5caa115daf21a0b3e9fa/runtime/lua/vim/ui.lua#L63-L80
- https://github.com/neovim/neovim/blob/61e71ccf8aa17a2fb6fe5caa115daf21a0b3e9fa/runtime/lua/vim/ui.lua#L126-L145
- https://github.com/neovim/neovim/blob/61e71ccf8aa17a2fb6fe5caa115daf21a0b3e9fa/runtime/doc/map.txt#L1450
- https://github.com/neovim/neovim/blob/61e71ccf8aa17a2fb6fe5caa115daf21a0b3e9fa/runtime/doc/lua.txt#L393-L425
- https://github.com/neovim/neovim/blob/61e71ccf8aa17a2fb6fe5caa115daf21a0b3e9fa/runtime/doc/api.txt#L3367-L3380
- https://github.com/neovim/neovim/blob/v0.10.0/runtime/doc/news.txt#L148-L161
- https://github.com/neovim/neovim/blob/61e71ccf8aa17a2fb6fe5caa115daf21a0b3e9fa/runtime/doc/channel.txt#L175-L195
- https://github.com/neovim/neovim/blob/61e71ccf8aa17a2fb6fe5caa115daf21a0b3e9fa/runtime/doc/options.txt#L1275-L1320
- https://github.com/Civitasv/cmake-tools.nvim/blob/782a254c62a61af1d4febddd0d6dbc5ea414a027/lua/cmake-tools/init.lua#L725-L770
- https://github.com/Civitasv/cmake-tools.nvim/blob/782a254c62a61af1d4febddd0d6dbc5ea414a027/lua/cmake-tools/init.lua#L86-L155
- https://github.com/Civitasv/cmake-tools.nvim/blob/782a254c62a61af1d4febddd0d6dbc5ea414a027/lua/cmake-tools/init.lua#L1612-L1660
- https://github.com/Civitasv/cmake-tools.nvim/blob/782a254c62a61af1d4febddd0d6dbc5ea414a027/lua/cmake-tools/init.lua#L1150-L1185
- https://github.com/Civitasv/cmake-tools.nvim/blob/782a254c62a61af1d4febddd0d6dbc5ea414a027/lua/cmake-tools/window.lua#L84-L100
- https://github.com/folke/lazy.nvim/blob/306a05526ada86a7b30af95c5cc81ffba93fef97/lua/lazy/view/float.lua#L118-L127
- https://github.com/folke/lazy.nvim/blob/306a05526ada86a7b30af95c5cc81ffba93fef97/lua/lazy/view/config.lua#L29-L39
- https://github.com/folke/lazy.nvim/blob/306a05526ada86a7b30af95c5cc81ffba93fef97/lua/lazy/view/render.lua#L103-L110
- https://github.com/folke/lazy.nvim/blob/306a05526ada86a7b30af95c5cc81ffba93fef97/lua/lazy/view/init.lua#L144-L160
- https://github.com/mason-org/mason.nvim/blob/2a6940af80375532e5e9e7c1f2fc6319a1b7a69d/lua/mason-core/ui/display.lua#L304-L382
- https://github.com/mason-org/mason.nvim/blob/2a6940af80375532e5e9e7c1f2fc6319a1b7a69d/lua/mason/settings.lua#L151-L181
- https://github.com/mason-org/mason.nvim/blob/2a6940af80375532e5e9e7c1f2fc6319a1b7a69d/lua/mason/ui/instance.lua#L505-L515
- https://github.com/stevearc/oil.nvim/blob/d3733d933833a0e59b813ecec99341527adf0c28/README.md#L134
- https://github.com/stevearc/oil.nvim/blob/d3733d933833a0e59b813ecec99341527adf0c28/lua/oil/config.lua#L26-L51
- https://github.com/stevearc/oil.nvim/blob/d3733d933833a0e59b813ecec99341527adf0c28/lua/oil/view.lua#L292-L320
- https://github.com/stevearc/oil.nvim/blob/d3733d933833a0e59b813ecec99341527adf0c28/lua/oil/mutator/init.lua#L500-L572
- https://github.com/NeogitOrg/neogit/blob/697ad3ee86a73cf6b6758b838d7a7d76cf3b9f86/lua/neogit/lib/buffer.lua#L73-L74
- https://github.com/NeogitOrg/neogit/blob/697ad3ee86a73cf6b6758b838d7a7d76cf3b9f86/lua/neogit/lib/popup/init.lua#L183-L205
- https://github.com/tpope/vim-fugitive/blob/3b753cf8c6a4dcde6edee8827d464ba9b8c4a6f0/doc/fugitive.txt#L286-L354
- https://github.com/MunifTanjim/nui.nvim/blob/10fc361835c856ba4233ef5ea135b919bf3dce97/lua/nui/input/init.lua#L50-L117
- https://github.com/MunifTanjim/nui.nvim/blob/10fc361835c856ba4233ef5ea135b919bf3dce97/README.md
- https://github.com/grapp-dev/nui-components.nvim/blob/1654dd709f13874089eefc80d82e0eb667f7fdfb/README.md
- https://github.com/folke/snacks.nvim/blob/882c996cf28183f4d63640de0b4c02ec886d01f2/docs/picker.md#L149
- https://github.com/folke/snacks.nvim/blob/882c996cf28183f4d63640de0b4c02ec886d01f2/docs/input.md
- https://github.com/folke/snacks.nvim/blob/882c996cf28183f4d63640de0b4c02ec886d01f2/lua/snacks/input.lua#L58
- https://github.com/ibhagwan/fzf-lua/blob/main/README.md
- https://github.com/nvim-telescope/telescope-ui-select.nvim/blob/master/README.md
- https://github.com/anurag3301/nvim-platformio.lua/blob/d5143c88698f78ce35fb5083b3668c94ea047a01/lua/platformio/pioinit.lua#L22-L35
- https://github.com/anurag3301/nvim-platformio.lua/blob/d5143c88698f78ce35fb5083b3668c94ea047a01/README.md#L69
- https://nrfconnectdocs.nordicsemi.com/ncs-bm/latest/nrf-bm/_sources/sample/intro/configure_and_build_sample.rst.txt
- https://devzone.nordicsemi.com/f/nordic-q-a/110115/nrf-connect-extension-build-configuration-cached-conf-and-extra-cmake-args/486453
- https://docs.nordicsemi.com/r/bundle/nrf-connect-vscode/page/release_notes/connect/2024.9.31.html/build-configuration

[nv-luatxt]: https://github.com/neovim/neovim/blob/61e71ccf8aa17a2fb6fe5caa115daf21a0b3e9fa/runtime/doc/lua.txt#L5650-L5760
[nv-ui-select]: https://github.com/neovim/neovim/blob/61e71ccf8aa17a2fb6fe5caa115daf21a0b3e9fa/runtime/lua/vim/ui.lua#L63-L80
[nv-ui-input]: https://github.com/neovim/neovim/blob/61e71ccf8aa17a2fb6fe5caa115daf21a0b3e9fa/runtime/lua/vim/ui.lua#L126-L145
[nv-maptxt]: https://github.com/neovim/neovim/blob/61e71ccf8aa17a2fb6fe5caa115daf21a0b3e9fa/runtime/doc/map.txt#L1450
[nv-vlua]: https://github.com/neovim/neovim/blob/61e71ccf8aa17a2fb6fe5caa115daf21a0b3e9fa/runtime/doc/lua.txt#L393-L425
[nv-apitxt]: https://github.com/neovim/neovim/blob/61e71ccf8aa17a2fb6fe5caa115daf21a0b3e9fa/runtime/doc/api.txt#L3367-L3380
[nv-news10]: https://github.com/neovim/neovim/blob/v0.10.0/runtime/doc/news.txt#L148-L161
[nv-prompt]: https://github.com/neovim/neovim/blob/61e71ccf8aa17a2fb6fe5caa115daf21a0b3e9fa/runtime/doc/channel.txt#L175-L195
[nv-optstxt]: https://github.com/neovim/neovim/blob/61e71ccf8aa17a2fb6fe5caa115daf21a0b3e9fa/runtime/doc/options.txt#L1275-L1320
[cmt-buildtype]: https://github.com/Civitasv/cmake-tools.nvim/blob/782a254c62a61af1d4febddd0d6dbc5ea414a027/lua/cmake-tools/init.lua#L725-L770
[cmt-generate]: https://github.com/Civitasv/cmake-tools.nvim/blob/782a254c62a61af1d4febddd0d6dbc5ea414a027/lua/cmake-tools/init.lua#L86-L155
[cmt-input]: https://github.com/Civitasv/cmake-tools.nvim/blob/782a254c62a61af1d4febddd0d6dbc5ea414a027/lua/cmake-tools/init.lua#L1612-L1660
[cmt-settings]: https://github.com/Civitasv/cmake-tools.nvim/blob/782a254c62a61af1d4febddd0d6dbc5ea414a027/lua/cmake-tools/init.lua#L1150-L1185
[cmt-window]: https://github.com/Civitasv/cmake-tools.nvim/blob/782a254c62a61af1d4febddd0d6dbc5ea414a027/lua/cmake-tools/window.lua#L84-L100
[lazy-float]: https://github.com/folke/lazy.nvim/blob/306a05526ada86a7b30af95c5cc81ffba93fef97/lua/lazy/view/float.lua#L118-L127
[lazy-keys]: https://github.com/folke/lazy.nvim/blob/306a05526ada86a7b30af95c5cc81ffba93fef97/lua/lazy/view/config.lua#L29-L39
[lazy-render]: https://github.com/folke/lazy.nvim/blob/306a05526ada86a7b30af95c5cc81ffba93fef97/lua/lazy/view/render.lua#L103-L110
[lazy-input]: https://github.com/folke/lazy.nvim/blob/306a05526ada86a7b30af95c5cc81ffba93fef97/lua/lazy/view/init.lua#L144-L160
[mason-display]: https://github.com/mason-org/mason.nvim/blob/2a6940af80375532e5e9e7c1f2fc6319a1b7a69d/lua/mason-core/ui/display.lua#L304-L382
[mason-keys]: https://github.com/mason-org/mason.nvim/blob/2a6940af80375532e5e9e7c1f2fc6319a1b7a69d/lua/mason/settings.lua#L151-L181
[mason-filter]: https://github.com/mason-org/mason.nvim/blob/2a6940af80375532e5e9e7c1f2fc6319a1b7a69d/lua/mason/ui/instance.lua#L505-L515
[oil-readme]: https://github.com/stevearc/oil.nvim/blob/d3733d933833a0e59b813ecec99341527adf0c28/README.md#L134
[oil-config]: https://github.com/stevearc/oil.nvim/blob/d3733d933833a0e59b813ecec99341527adf0c28/lua/oil/config.lua#L26-L51
[oil-view]: https://github.com/stevearc/oil.nvim/blob/d3733d933833a0e59b813ecec99341527adf0c28/lua/oil/view.lua#L292-L320
[oil-mutator]: https://github.com/stevearc/oil.nvim/blob/d3733d933833a0e59b813ecec99341527adf0c28/lua/oil/mutator/init.lua#L500-L572
[neogit-buf]: https://github.com/NeogitOrg/neogit/blob/697ad3ee86a73cf6b6758b838d7a7d76cf3b9f86/lua/neogit/lib/buffer.lua#L73-L74
[neogit-popup]: https://github.com/NeogitOrg/neogit/blob/697ad3ee86a73cf6b6758b838d7a7d76cf3b9f86/lua/neogit/lib/popup/init.lua#L183-L205
[fug-doc]: https://github.com/tpope/vim-fugitive/blob/3b753cf8c6a4dcde6edee8827d464ba9b8c4a6f0/doc/fugitive.txt#L286-L354
[nui-input]: https://github.com/MunifTanjim/nui.nvim/blob/10fc361835c856ba4233ef5ea135b919bf3dce97/lua/nui/input/init.lua#L50-L117
[nui-readme]: https://github.com/MunifTanjim/nui.nvim/blob/10fc361835c856ba4233ef5ea135b919bf3dce97/README.md
[nuicomp-readme]: https://github.com/grapp-dev/nui-components.nvim/blob/1654dd709f13874089eefc80d82e0eb667f7fdfb/README.md
[snacks-picker]: https://github.com/folke/snacks.nvim/blob/882c996cf28183f4d63640de0b4c02ec886d01f2/docs/picker.md#L149
[snacks-input]: https://github.com/folke/snacks.nvim/blob/882c996cf28183f4d63640de0b4c02ec886d01f2/docs/input.md
[snacks-input-src]: https://github.com/folke/snacks.nvim/blob/882c996cf28183f4d63640de0b4c02ec886d01f2/lua/snacks/input.lua#L58
[fzf-readme]: https://github.com/ibhagwan/fzf-lua/blob/main/README.md
[tele-uiselect]: https://github.com/nvim-telescope/telescope-ui-select.nvim/blob/master/README.md
[pio-init]: https://github.com/anurag3301/nvim-platformio.lua/blob/d5143c88698f78ce35fb5083b3668c94ea047a01/lua/platformio/pioinit.lua#L22-L35
[pio-readme]: https://github.com/anurag3301/nvim-platformio.lua/blob/d5143c88698f78ce35fb5083b3668c94ea047a01/README.md#L69
[nrf-bm-rst]: https://nrfconnectdocs.nordicsemi.com/ncs-bm/latest/nrf-bm/_sources/sample/intro/configure_and_build_sample.rst.txt
[devzone-cmake]: https://devzone.nordicsemi.com/f/nordic-q-a/110115/nrf-connect-extension-build-configuration-cached-conf-and-extra-cmake-args/486453
[nrf-rn]: https://docs.nordicsemi.com/r/bundle/nrf-connect-vscode/page/release_notes/connect/2024.9.31.html/build-configuration

- Neovim: `vim.ui` docs and source, `nvim_open_win`, extmarks, prompt buffers,
  `'buftype'`, `input()` completion, `v:lua` (links above, master @ `61e71cc`).
- cmake-tools.nvim @ `782a254`, lazy.nvim @ `306a055`, mason.nvim @ `2a6940a`,
  oil.nvim @ `d3733d9`, neogit @ `697ad3e`, vim-fugitive @ `3b753cf`,
  nui.nvim @ `10fc361`, nui-components.nvim @ `1654dd7`, snacks.nvim @ `882c996`,
  nvim-platformio.lua @ `d5143c8`.
- Nordic: nRF Connect SDK Bare Metal "configure and build sample" (VS Code
  steps), DevZone thread 110115, nRF Connect for VS Code release notes 2024.9.31.
  The full "Build Configuration page" reference
  (docs.nordicsemi.com/…/ui_sidebar_applications.html) renders client-side and
  could not be read.
