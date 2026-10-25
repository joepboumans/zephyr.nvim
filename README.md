# zephyr.nvim

Vendor-neutral [Zephyr](https://zephyrproject.org) support for Neovim, built as a Lua API of **components** (workspace, build, flash, RTT, clangd, Zephyr SDK) that UIs are assembled from. A default UI (`:Zephyr`) ships with it and uses only the public API.

Vendor plugins such as [nrf-connect.nvim](https://github.com/joepboumans/nrf-connect.nvim) extend it by registering toolchain providers and probe finders (see [ADR 0001](docs/adr/0001-vendor-plugins-extend-through-registries.md)).

> Status: early. Workspace detection, toolchains and drift detection/update work; build, flash, RTT and clangd are stubs.

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

- `:Zephyr sdk list` shows the toolchains found by every provider; `*` marks the active one.
- `:Zephyr sdk select` picks the active toolchain for the current west workspace. The choice is kept per workspace in Neovim's data folder.
- `:Zephyr sdk install [version]` runs `west sdk install` (Zephyr 4.0+) in the workspace.

- `:Zephyr update check` reports **drift**: projects whose checkout (`HEAD`) is not on the revision the manifest names (`manifest-rev`, or the SHA pinned in the manifest).
- `:Zephyr update [project...]` shows the drifted projects, asks for confirmation (all projects, only the drifted ones, or cancel) and runs `west update` with its output streamed into a split.

When you open a file inside a west workspace, its drift is checked once per session, and again after you write its manifest. Nothing is updated automatically; a notification gives the count and points to `:Zephyr update`. Turn it off with `require("zephyr").setup({ drift = { auto_check = false } })`.

From Lua: `require("zephyr").drift.check(workspace, function(drifted, err) end)` gives `{ name, path, abspath, expected, actual }` per drifted project, and `require("zephyr").update(workspace, { projects = {...}, on_output = function(line, stream) end }, function(ok, result) end)` runs `west update`. They fire `ZephyrDriftDetected` and `ZephyrUpdateFinished`.

The Zephyr SDK is found through `ZEPHYR_SDK_INSTALL_DIR` and the default install locations (`~`, `~/.local`, `~/.local/opt`, `~/bin`, `/opt`, `/usr`, `/usr/local`).

## Events

Components fire `User` autocmds named `Zephyr<Event>` (for example `ZephyrBuildFinished`, `ZephyrDriftDetected`, `ZephyrUpdateFinished`, `ZephyrToolchainActivated`) with details in `ev.data`.

## Development

`make test` runs the plenary-busted suite headless. Vocabulary lives in [CONTEXT.md](CONTEXT.md).
