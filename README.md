# zephyr.nvim

Vendor-neutral [Zephyr](https://zephyrproject.org) support for Neovim, built as a Lua API of **components** (workspace, build, flash, RTT, clangd, Zephyr SDK) that UIs are assembled from. A default UI (`:Zephyr`) ships with it and uses only the public API.

Vendor plugins such as [nrf-connect.nvim](https://github.com/joepboumans/nrf-connect.nvim) extend it by registering toolchain providers and probe finders (see [ADR 0001](docs/adr/0001-vendor-plugins-extend-through-registries.md)).

> Status: early. Workspace detection, build configurations with their own settings, toolchains, builds, flashing, RTT, drift detection/update and clangd setup work. Tested with recorded CLI output; first real use found the issues in [docs/known-issues.md](docs/known-issues.md), handled by the [refinements spec](docs/specs/refinements.md).

## Requirements

- Neovim 0.10+, no other runtime dependencies
- `west`, `cmake` and `ninja` on `PATH`
- Linux or WSL for now; macOS and Windows later

## Install (lazy.nvim)

```lua
{ "joepboumans/zephyr.nvim", opts = {} }
```

Run `:checkhealth zephyr` to see what it finds.

## Commands

`:Zephyr build | flash | rtt | update | sdk | clangd`

- `:Zephyr build` runs `west build` for the active build configuration of the current app, with that build configuration's toolchain environment. Output streams into the **Output window**; errors and warnings (GCC, LD, CMake, Kconfig, devicetree) go to quickfix, which opens when there are errors. When CMake configure fails on Kconfig or in sysbuild, the reason comes first in quickfix, even without a file and line. With no build configuration yet it opens the settings panel first.
- When the current file is not inside an app (for example a shared library the manifest exports next to it), `:Zephyr build`, `:Zephyr flash` and `:Zephyr rtt` use the workspace's **active app**: the one built last. With none yet, a picker lists the apps found in the manifest repository and those with build configurations. `:Zephyr build app` picks another one.
- `:Zephyr build pristine` does the same with `-p always`.
- `:Zephyr build select` picks the active build configuration of the app. The choice is personal and kept per app in Neovim's data folder.
- `:Zephyr build new` and `:Zephyr build edit` open a build configuration in a read-only **settings panel**: one labelled row per setting (board target, build directory, Kconfig files, extra Kconfig files, DT overlays, snippets, sysbuild, optimization, board roots, CMake arguments, toolchain), with `—` for empty values and a dim hint where a default applies. `new` starts with the board picker (custom boards from board roots included); `edit` opens the active build configuration. `<CR>` or `i` on a row changes it: sysbuild toggles, board, optimization and toolchain open a picker, Kconfig files, overlays and snippets open a toggle picker (pick items to add or remove them, `Done` to finish), and build directory, CMake arguments (space separated) and board roots open an input. `x` resets a row to its default, `<C-s>` saves and closes, `q` closes without saving, `<Esc>` closes unless there are unsaved changes, `g?` lists the keys. Every picker goes through `vim.ui.select` with a `kind` of `zephyr.<field>` (for example `zephyr.board`), so telescope, fzf-lua or snacks can style it. A save with errors keeps the panel open and shows each error on its row. After an edit that needs CMake to configure again it asks: pristine build now, on the next build, or not now; with `setup({ build = { auto_pristine = true } })` the next build is pristine without asking.
- **Build configuration settings** live in `<topdir>/.zephyr/build-configs.json` (git-ignored through `.zephyr/.gitignore`), keyed by the app's path, with paths relative to the app (board roots relative to the topdir) and toolchains by provider and version, so the file works on another machine. Every configure passes all of them (`-b`, `--sysbuild`/`--no-sysbuild`, `-S`, `CONF_FILE`, `EXTRA_CONF_FILE`, `EXTRA_DTC_OVERLAY_FILE`, `BOARD_ROOT`, the `CONFIG_*_OPTIMIZATIONS` fragment, then the extra CMake arguments after `--`), so a pristine build recreates the build directory exactly. An incremental build lets west reuse the cache.
- A build directory without settings (made by the nRF Connect VS Code extension or by hand) is imported the first time it is seen, from its CMake cache and `build_info.yml`, with a notification. From then on the settings win: when a build directory was configured differently, `:Zephyr build` says how and offers a pristine build. zephyr.nvim never writes VS Code's settings.
- **Board roots**: besides what Zephyr finds itself (the app's `boards/`, modules' `board_root`), the topdir is added when `<topdir>/boards/` exists, the manifest repository when it has `boards/`, and the `board_roots` of the settings. They go to configure as `BOARD_ROOT` and to `west boards` as `--board-root`, so custom boards are listed too.
- The **Output window** is shared by build, flash and update. `q` or `<Esc>` in it closes it, and `:Zephyr output close` closes every Output window from anywhere (bind it yourself, e.g. `vim.keymap.set("n", "<leader>zq", "<cmd>Zephyr output close<cr>")`). While a command runs, closing stops it (and what west started) first. Every other key works as usual. `require("zephyr.ui.output").show()` shows it again.
- `:Zephyr flash` runs `west flash` for the active build configuration with its toolchain's environment, through the active probe (`--dev-id`). West uses the board's `flash-runner` from `runners.yaml` (of the app's image under sysbuild, where west flashes every image in `flash_order`). Output streams into the Output window. With several probes connected and none chosen yet it asks once which one to use.
- `:Zephyr flash erase` does the same with `--erase` (mass erase first).
- `:Zephyr flash probe` picks the active probe among the connected ones, listed by every probe finder (J-Link Commander's `ShowEmuList`, plus finders from plugins such as nrf-connect.nvim). The choice is kept per workspace in Neovim's data folder.
- `:Zephyr rtt` opens the **RTT viewer** in a bottom terminal split: `west rtt -d <build dir> --dev-id <serial>` (Zephyr 4.0+, runners jlink, pyocd and openocd; `-r jlink` is added when the board's debug-runner cannot do RTT) with the build configuration's toolchain environment, through the active probe. On older Zephyr (where `west rtt --help` fails; checked once per Zephyr base) it falls back to `JLinkGDBServer -if SWD -speed auto -device <--device of the jlink runner in runners.yaml> -rtttelnetport 19021 -nohalt -nogui -select usb=<serial>` in the background and `JLinkRTTClient -RTTTelnetPort 19021` in the terminal; the server stops with the terminal, or when Neovim exits. The fallback needs the SEGGER J-Link tools on `PATH` and uses GDB port 2331, so it cannot run next to another J-Link GDB server. Running `:Zephyr rtt` again shows the running viewer.
- `:Zephyr rtt stop` stops the RTT viewer (and stream) started by `:Zephyr rtt`.
- The **active toolchain** belongs to a build configuration. Without one chosen, the default is a vendor toolchain ranked by its provider (nrf-connect.nvim ranks the NCS toolchain matching the workspace's NCS version first, then the newest), and the Zephyr SDK only when no other toolchain is installed, preferring the version in `<zephyr>/SDK_VERSION`. When the settings name a toolchain that isn't installed, a warning says which default is used instead and offers to install it. When the toolchain's environment can't be resolved (provider missing, `nrfutil` missing or failing), build, flash and RTT don't start and say why. The first line of the Output window names the toolchain used. A workspace's toolchain choice from before is used once for its build configurations, then dropped.
- `:Zephyr sdk list` shows the toolchains found by every provider, default first; `*` marks the active build configuration's.
- `:Zephyr sdk select` picks the toolchain of the active build configuration and stores it in its settings.
- `:Zephyr sdk install [version]` runs `west sdk install` (Zephyr 4.0+) in the workspace.
- `:Zephyr clangd` writes `<app>/.clangd` pointing clangd at the active build configuration's `compile_commands.json` (the app image's build dir under sysbuild) and removing GCC-only flags clang rejects. It reports what it wrote, or why not: a `.clangd` without zephyr.nvim's first-line marker is never overwritten. A generated `.clangd` follows along when another build configuration is activated and after each successful build. Options: `setup({ clangd = { remove = {...}, add = {...}, auto_write = true } })`; `remove`/`add` replace the defaults in `require("zephyr.clangd").default_remove`/`default_add`.
- clangd needs `--query-driver` (a command-line flag only) to find the toolchain's headers: `require("zephyr.clangd").cmd(workspace, app)` gives `{ "clangd", "--query-driver=<gcc of the active build configuration's toolchain>" }` (without `app`, the workspace's active app), and `require("zephyr.clangd").setup_lsp()` starts clangd with it on C/C++ buffers inside a west workspace. Call it yourself; it is not started otherwise.

- `:Zephyr update check` reports **drift**: projects whose checkout (`HEAD`) is not on the revision the manifest names (`manifest-rev`, or the SHA pinned in the manifest). It also reports **pin mismatches**: projects the manifest pins at another revision than a manifest it imports (for example a Zephyr fork pinned next to an NCS fork whose own `west.yml` pins another Zephyr), as a warning naming both revisions. Pin mismatches never block a build.
- `:Zephyr update [project...]` shows the drifted projects, asks for confirmation (all projects, only the drifted ones, or cancel) and runs `west update` with its output streamed into the Output window.

When you open a file inside a west workspace, its drift and pin mismatches are checked once per session, and again after you write its manifest. Nothing is updated automatically; a notification gives the count and points to `:Zephyr update`. Turn it off with `require("zephyr").setup({ drift = { auto_check = false } })`.

From Lua: `require("zephyr").drift.check(workspace, function(drifted, err, mismatches) end)` gives `{ name, path, abspath, expected, actual }` per drifted project and `{ name, revision, imported_revision, imported_from, imported_file }` per pin mismatch (also `require("zephyr.manifest").pin_mismatches(workspace)`), and `require("zephyr").update(workspace, { projects = {...}, on_output = function(line, stream) end }, function(ok, result) end)` runs `west update`. They fire `ZephyrDriftDetected`, `ZephyrUpdateStarted` and `ZephyrUpdateFinished`.

From Lua: `require("zephyr.build_config")` has `list(app)`, `get(app, dir)`, `active(app)`, `activate(app, cfg)`, `new(app, { board = ..., extra_conf_files = {...}, ... })`, `save(app, settings, old_dir)`, `validate(app, settings)`, `differences(app, cfg)`, `board_roots(app, settings)` and `boards(app, cb, settings)` for the build configurations of an app (`require("zephyr.app").find()`, or `require("zephyr.app").active(workspace)`); each has `cfg.settings`. `require("zephyr.build").run(app, cfg, { pristine = true, on_start = function(info) end, on_output = function(line, stream) end, on_exit = function(result) end })` builds one, with `result.items` as quickfix items, and `require("zephyr.build").stop(cfg.dir)` stops it. `require("zephyr.toolchain")` has `resolve(app, cfg)`, `active(app, cfg)`, `activate(app, cfg, tc)`, `env(app, cfg)` and `default(workspace)`; a toolchain provider may add `rank(toolchains, workspace)` to order its toolchains for a workspace.

From Lua: `require("zephyr.probes").list()` gives the connected probes as `{ finder, serial, name }`, `require("zephyr.probes").select(workspace, probe)` makes one active, and `require("zephyr.flash").run(app, cfg, { runner = "jlink", probe = probe, erase = true, on_output = function(line, stream) end, on_exit = function(result) end })` flashes.

From Lua, the **RTT stream** gives RTT output as lines for your own RTT viewer: `local s = require("zephyr.rtt").stream({ host = "127.0.0.1", port = 19021, retries = 10, retry_delay = 300, on_connect = function() end, on_close = function(err) end }, function(line) end)` connects to the RTT telnet port (retrying while the server starts), calls `on_line` on the main loop for each line, and returns `s.send(text)`, `s.close()` and `s.is_connected()`. Something must serve RTT on that port (a `:Zephyr rtt` viewer, J-Link Commander, RTT Viewer), or pass `start_server = true, app = app, config = cfg` (optionally `probe`) to start JLinkGDBServer, which is stopped on `close()`. `require("zephyr.rtt").open_viewer(app, cfg, { probe = probe, win = win, on_exit = function(code) end }, function(viewer, err) end)` opens the RTT viewer in `win` and gives `{ buf, job, mode, cmd, stop }`; `west_command`, `server_command` and `client_command` build the command lines.

The Zephyr SDK is found through `ZEPHYR_SDK_INSTALL_DIR` and the default install locations (`~`, `~/.local`, `~/.local/opt`, `~/bin`, `/opt`, `/usr`, `/usr/local`).

## Events

Components fire `User` autocmds named `Zephyr<Event>` (for example `ZephyrBuildFinished`, `ZephyrDriftDetected`, `ZephyrUpdateFinished`, `ZephyrToolchainActivated`) with details in `ev.data`.

Build, flash and update run as Jobs, one at a time per build directory (or Workspace): starting a flash while that Build configuration builds fails with "<name> is busy (building)", and the other way round with "(flashing)".

- `ZephyrBuildStarted`: `app`, `build_dir`, `board`, `cmd`, `toolchain`
- `ZephyrBuildFinished`: `app`, `build_dir`, `board`, `toolchain`, `ok`, `code`, `stopped`, `duration` (seconds), `items` (quickfix items)
- `ZephyrBuildConfigActivated`: `app`, `build_dir`, `board`
- `ZephyrBuildConfigImported`: `app`, `build_dir`, `name`, `board`
- `ZephyrAppActivated`: `workspace`, `app`
- `ZephyrDriftDetected`: `workspace`, `projects` (the drifted projects, as `drift.check` gives them), `pin_mismatches`
- `ZephyrUpdateStarted`: `workspace`, `projects` (empty for all), `cmd`
- `ZephyrUpdateFinished`: `workspace`, `projects` (empty for all), `ok`, `code`, `stopped`, `duration` (seconds)
- `ZephyrToolchainActivated`: `workspace`, `app`, `build_dir` (the build configuration), `toolchain` (`{ provider, id, name, version, path }`)
- `ZephyrRegistered`: `kind` (`"toolchain_provider"` or `"probe_finder"`), `name`
- `ZephyrFlashStarted`: `app`, `build_dir`, `runner`, `probe`, `cmd`
- `ZephyrFlashFinished`: `app`, `build_dir`, `runner`, `probe`, `ok`, `code`, `stopped`, `duration` (seconds)
- `ZephyrProbeSelected`: `workspace`, `probe` (`{ finder, serial, name }`)
- `ZephyrClangdWritten`: `app`, `path`, `build_dir`
- `ZephyrRttStarted`: RTT viewer: `kind = "viewer"`, `mode` (`"west"` or `"jlink"`), `app`, `build_dir`, `probe`, `cmd`; RTT stream: `kind = "stream"`, `host`, `port` (and `probe` with `start_server`)
- `ZephyrRttStopped`: the same, plus `code` (viewer) or `err` (stream, when it failed)

## Development

`make test` runs the plenary-busted suite headless. Vocabulary lives in [CONTEXT.md](CONTEXT.md). Open problems and their likely causes are in [docs/known-issues.md](docs/known-issues.md).

There is no CI on purpose, because hosted CI costs money. Run `make test` locally before you open or merge a PR, and don't add GitHub Actions workflows.
