# zephyr.nvim

Vendor-neutral [Zephyr](https://zephyrproject.org) support for Neovim, built as a Lua API of **components** (workspace, build, flash, RTT, clangd, Zephyr SDK) that UIs are assembled from. A default UI (`:Zephyr`) ships with it and uses only the public API.

Vendor plugins such as [nrf-connect.nvim](https://github.com/joepboumans/nrf-connect.nvim) extend it by registering toolchain providers and probe finders (see [ADR 0001](docs/adr/0001-vendor-plugins-extend-through-registries.md)).

> Status: early. Workspace detection, toolchains, builds, flashing, drift detection/update and RTT work; clangd is a stub.

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

- `:Zephyr build` runs `west build` for the active build configuration of the current app, with the active toolchain's environment. Output streams into a split; errors and warnings (GCC, LD, CMake, Kconfig, devicetree) go to quickfix, which opens when there are errors. With no build configuration yet it asks for a board first.
- `:Zephyr build pristine` does the same with `-p always`.
- `:Zephyr build select` picks the active build configuration among the app's build directories (plain and sysbuild). The choice is kept per app in Neovim's data folder.
- `:Zephyr build new` picks a board from `west boards` (or takes one typed in) and makes `build_<board>` (with `/` replaced by `_`) the active build configuration; `:Zephyr build` then configures it.
- `:Zephyr flash` runs `west flash` for the active build configuration with the active toolchain's environment, through the active probe (`--dev-id`). West uses the board's `flash-runner` from `runners.yaml` (of the app's image under sysbuild, where west flashes every image in `flash_order`). Output streams into a split. With several probes connected and none chosen yet it asks once which one to use.
- `:Zephyr flash erase` does the same with `--erase` (mass erase first).
- `:Zephyr flash probe` picks the active probe among the connected ones, listed by every probe finder (J-Link Commander's `ShowEmuList`, plus finders from plugins such as nrf-connect.nvim). The choice is kept per workspace in Neovim's data folder.
- `:Zephyr rtt` opens the **RTT viewer** in a bottom terminal split: `west rtt -d <build dir> --dev-id <serial>` (Zephyr 4.0+, runners jlink, pyocd and openocd; `-r jlink` is added when the board's debug-runner cannot do RTT) with the active toolchain's environment, through the active probe. On older Zephyr (where `west rtt --help` fails; checked once per Zephyr base) it falls back to `JLinkGDBServer -if SWD -speed auto -device <--device of the jlink runner in runners.yaml> -rtttelnetport 19021 -nohalt -nogui -select usb=<serial>` in the background and `JLinkRTTClient -RTTTelnetPort 19021` in the terminal; the server stops with the terminal. The fallback needs the SEGGER J-Link tools on `PATH` and uses GDB port 2331, so it cannot run next to another J-Link GDB server. Running `:Zephyr rtt` again shows the running viewer.
- `:Zephyr rtt stop` stops the RTT viewer (and stream) started by `:Zephyr rtt`.
- `:Zephyr sdk list` shows the toolchains found by every provider; `*` marks the active one.
- `:Zephyr sdk select` picks the active toolchain for the current west workspace. The choice is kept per workspace in Neovim's data folder.
- `:Zephyr sdk install [version]` runs `west sdk install` (Zephyr 4.0+) in the workspace.

- `:Zephyr update check` reports **drift**: projects whose checkout (`HEAD`) is not on the revision the manifest names (`manifest-rev`, or the SHA pinned in the manifest).
- `:Zephyr update [project...]` shows the drifted projects, asks for confirmation (all projects, only the drifted ones, or cancel) and runs `west update` with its output streamed into a split.

When you open a file inside a west workspace, its drift is checked once per session, and again after you write its manifest. Nothing is updated automatically; a notification gives the count and points to `:Zephyr update`. Turn it off with `require("zephyr").setup({ drift = { auto_check = false } })`.

From Lua: `require("zephyr").drift.check(workspace, function(drifted, err) end)` gives `{ name, path, abspath, expected, actual }` per drifted project, and `require("zephyr").update(workspace, { projects = {...}, on_output = function(line, stream) end }, function(ok, result) end)` runs `west update`. They fire `ZephyrDriftDetected` and `ZephyrUpdateFinished`.

From Lua: `require("zephyr.probes").list()` gives the connected probes as `{ finder, serial, name }`, `require("zephyr.probes").select(workspace, probe)` makes one active, and `require("zephyr.flash").run(app, cfg, { runner = "jlink", probe = probe, erase = true, on_output = function(line, stream) end, on_exit = function(result) end })` flashes.

From Lua, the **RTT stream** gives RTT output as lines for your own RTT viewer: `local s = require("zephyr.rtt").stream({ host = "127.0.0.1", port = 19021, retries = 10, retry_delay = 300, on_connect = function() end, on_close = function(err) end }, function(line) end)` connects to the RTT telnet port (retrying while the server starts), calls `on_line` on the main loop for each line, and returns `s.send(text)`, `s.close()` and `s.is_connected()`. Something must serve RTT on that port (a `:Zephyr rtt` viewer, J-Link Commander, RTT Viewer), or pass `start_server = true, app = app, config = cfg` (optionally `probe`) to start JLinkGDBServer, which is stopped on `close()`. `require("zephyr.rtt").open_viewer(app, cfg, { probe = probe, win = win, on_exit = function(code) end }, function(viewer, err) end)` opens the RTT viewer in `win` and gives `{ buf, job, mode, cmd, stop }`; `west_command`, `server_command` and `client_command` build the command lines.

The Zephyr SDK is found through `ZEPHYR_SDK_INSTALL_DIR` and the default install locations (`~`, `~/.local`, `~/.local/opt`, `~/bin`, `/opt`, `/usr`, `/usr/local`).

## Events

Components fire `User` autocmds named `Zephyr<Event>` (for example `ZephyrBuildFinished`, `ZephyrDriftDetected`, `ZephyrUpdateFinished`, `ZephyrToolchainActivated`) with details in `ev.data`.

- `ZephyrBuildStarted`: `app`, `build_dir`, `board`, `cmd`
- `ZephyrBuildFinished`: `app`, `build_dir`, `ok`, `code`, `duration` (seconds), `items` (quickfix items)
- `ZephyrBuildConfigActivated`: `app`, `build_dir`, `board`
- `ZephyrFlashStarted`: `app`, `build_dir`, `runner`, `probe`, `cmd`
- `ZephyrFlashFinished`: `app`, `build_dir`, `runner`, `probe`, `ok`, `code`, `duration` (seconds)
- `ZephyrProbeSelected`: `workspace`, `probe` (`{ finder, serial, name }`)
- `ZephyrRttStarted`: RTT viewer: `kind = "viewer"`, `mode` (`"west"` or `"jlink"`), `app`, `build_dir`, `probe`, `cmd`; RTT stream: `kind = "stream"`, `host`, `port` (and `probe` with `start_server`)
- `ZephyrRttStopped`: the same, plus `code` (viewer) or `err` (stream, when it failed)

## Development

`make test` runs the plenary-busted suite headless. Vocabulary lives in [CONTEXT.md](CONTEXT.md).
