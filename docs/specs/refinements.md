# Spec: refinements after first real use

Settled with Joep in a grilling session on 2026-10-27, covering the [known issues](../known-issues.md). Terms are from [CONTEXT.md](../../CONTEXT.md). Nothing here is built yet.

## Goals

- A Build configuration can be recreated from scratch, so Pristine builds and edits work (known issues 3, 4, 5).
- The right Toolchain is used, per Build configuration, or the build refuses to start (issues 1, 6).
- Output windows are easy to close (issue 2).
- Configure failures show up in quickfix (issue 4).
- Build and flash work from any file in the Workspace, not only inside the App.

## 1. Build configurations own their settings

A Build configuration holds, like the nRF Connect VS Code extension's build configurations:

| Field | Passed as |
| --- | --- |
| board | `-b` |
| config files | `-DCONF_FILE=` |
| extra Kconfig fragments | `-DEXTRA_CONF_FILE=` |
| devicetree overlays | `-DEXTRA_DTC_OVERLAY_FILE=` |
| snippets | `-S` |
| sysbuild on/off | `--sysbuild` / `--no-sysbuild` |
| optimisation level | the matching `CONFIG_*_OPTIMIZATIONS=y` fragment |
| board roots (beyond the defaults, see 5) | `-DBOARD_ROOT=` |
| extra CMake arguments | after `--` |
| Toolchain | provider and version, see 3 |
| build directory | `-d` |

zephyr.nvim stores these itself and passes all of them on every configure, so a Pristine build recreates the build directory exactly.

**Settings win.** If a build directory was configured with something else (for example `west build` run by hand), `:Zephyr build` warns about the difference and offers a Pristine build.

### Where they live

One JSON file per Workspace: `<topdir>/.zephyr/build-configs.json`, with every App's Build configurations keyed by the App's path relative to `<topdir>`. The `.zephyr/` directory holds its own `.gitignore` containing `*`, so git ignores it without anyone changing the team's `.gitignore`. Toolchains are stored by provider and version, not by path, so the file works on another machine.

Personal state (Neovim's data folder) keeps which Build configuration is active per App, and the Active app per Workspace.

### Importing VS Code Build configurations

The first time zephyr.nvim sees a build directory with no settings (for example one made by VS Code), it imports it: board, conf files, overlays, snippets, sysbuild and board roots are read from the CMake cache and `build_info.yml`, and a notification says it was imported. From then on the settings win. zephyr.nvim never writes VS Code settings.

## 2. Creating and editing

`:Zephyr build new` and `:Zephyr build edit` open the same editable buffer in a float, pre-filled for `new`:

- One `field: value` line per setting.
- `<Tab>` completes values: boards (including custom boards, see 5), conf and overlay files in the App, snippets, Toolchains.
- `<CR>` on a line opens a picker for that field.
- `:w` saves, `q` cancels.

After saving an edit that needs CMake to reconfigure (board, conf files, overlays, snippets, sysbuild, board roots, CMake arguments, Toolchain), it asks: "Pristine build now / On the next build / Not now". With `setup({ build = { auto_pristine = true } })` it doesn't ask and the next build is pristine.

## 3. Toolchain per Build configuration

The Active toolchain belongs to a Build configuration, not to the Workspace. `:Zephyr sdk select` sets it for the active Build configuration; build, flash, RTT and clangd's `--query-driver` all use it. No per-Workspace choice is left.

With no Toolchain chosen, the default is:

1. the NCS toolchain matching the NCS version of the Workspace, read from `<nrf project>/VERSION` (a customised fork may pin a branch or SHA), falling back to the first version-looking part of the revision in the Manifest (`vt-v2.9.2-v1.5` gives `v2.9.2`);
2. else the newest NCS toolchain installed;
3. the Zephyr SDK only when no NCS toolchain is installed, preferring the version in the Workspace's `zephyr/SDK_VERSION` (the Zephyr checkout may be a fork, e.g. `vt-3.7.99-ncs2-2-v1.7`).

If the Toolchain's environment can't be resolved (provider missing, `nrfutil` missing or failing), the build or flash does not start, and the error says why. The first line of the Output window names the Toolchain used.

If the settings name a Toolchain that isn't installed on this machine, a warning offers to install it. Until it's installed, builds use the default, and the warning says which.

Migration: a Workspace's old Toolchain choice is used once as the Toolchain of its Build configurations, then dropped.

The NCS toolchain provider (nrf-connect.nvim) needs no new API for this; zephyr.nvim asks providers by version as today.

## 4. Building from outside the App

A Manifest often exports shared files next to the App (`workspace/app/west.yml` exports `workspace/nrflib`, `workspace/scripts`). When the current file is not inside an App, `:Zephyr build`, `:Zephyr flash` and `:Zephyr rtt` use the Workspace's **Active app**: the one built last. If there is none yet, a picker lists the Apps found in the manifest repository (Zephyr, NCS and modules skipped). `:Zephyr build app` switches it.

## 5. Board roots

Zephyr already finds boards in the App's `boards/` and in modules' `board_root`. zephyr.nvim adds:

- `<topdir>` when `<topdir>/boards/` exists;
- the manifest repository when it has a `boards/` directory;
- any `board_roots` listed in the settings file.

These are passed as `-DBOARD_ROOT=` on configure and as `--board-root` to `west boards`, so `:Zephyr build new` lists custom boards too.

## 6. Output windows

Build, flash and update share one Output window (update moves onto `ui/output.lua`). Only `q` closes it:

- while a command runs, `q` stops it and closes the window;
- once it has finished, `q` closes the window.

Every other key works as usual, so the output can be scrolled and searched.

## 7. Configure failures in quickfix

Kconfig and sysbuild failures reach quickfix even without a file and line, as entries with no file, listed first. The Kconfig message itself (not just "command failed with return code: 1") is the entry text. Relative paths in CMake messages (for example `cmake/modules/sysbuild_extensions.cmake`) are resolved against `ZEPHYR_BASE`.

## 8. Zephyr pinned differently from NCS

When the Workspace's Manifest pins Zephyr itself (as a Zephyr fork next to an NCS fork), zephyr.nvim compares that revision with the one the NCS fork's own `west.yml` pins. A difference is a **Pin mismatch**: it is reported with Drift (on opening a Workspace file, after writing the Manifest, and by `:Zephyr update check`), as a warning that names both revisions. It never blocks a build.

## Settled details

- The settings file is JSON, because Neovim reads and writes it with `vim.json` while YAML would need a dependency.
- Both NCS and Zephyr may be forks pinned by the Workspace's Manifest, with their own revision names. Versions are always read from the checkouts (`<nrf>/VERSION`, `<zephyr>/VERSION`, `<zephyr>/SDK_VERSION`), never assumed from a release tag.
