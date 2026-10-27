# Known issues

Problems found while using zephyr.nvim (with nrf-connect.nvim) on a real App. Each one lists what happens, the likely causes found by reading the code, and the questions to settle in the next grilling session. How they are solved is in [the refinements spec](specs/refinements.md), built in tickets #12 to #21; this file keeps the original reports.

Issues 1 to 3 were found 2026-10-25 on Linux, building `happy-bots/app` against a customised NCS Workspace with an NCS toolchain in `~/ncs/toolchains/b77d8c1312`. Issues 4 to 6 were found 2026-10-27 on the `vt-wockel-sdk` Workspace.

## 1. `:Zephyr build` and `:Zephyr flash` fail with `No module named 'ninja'`

What happens:

```
$ west build -d /home/joep/projects/happy-bots/app/build
Traceback (most recent call last):
  File "/home/joep/ncs/toolchains/b77d8c1312/usr/local/bin/ninja", line 5, in <module>
    from ninja import ninja
ModuleNotFoundError: No module named 'ninja'
FATAL ERROR: command exited with status 1: /usr/bin/cmake --build /home/joep/projects/happy-bots/app/build
```

`:Zephyr flash` fails the same way, because `west flash` rebuilds first.

Update 2026-10-27: picking a better NCS toolchain with `:Zephyr sdk select` makes the error go away. So the environment works once the right toolchain is active; the open problem is that the default choice was wrong and nothing said so.

What the output tells us:

- The `ninja` in the NCS toolchain is not a binary but a pip launcher script that imports the `ninja` Python package. It only works when it runs under the toolchain's Python, with the toolchain's `PYTHONHOME`/`PYTHONPATH`.
- CMake is `/usr/bin/cmake`, the host's, not the one in the NCS toolchain. So the build ran without the NCS toolchain's `PATH`: the Active toolchain's environment was not applied.
- CMake still used the toolchain's `ninja`, most likely because `CMAKE_MAKE_PROGRAM` is cached in `build/CMakeCache.txt` from an earlier configure that did have the toolchain environment (a `nrfutil ... toolchain launch` shell, or VS Code).

Likely causes, most likely first:

1. **No NCS toolchain provider is loaded.** nrf-connect.nvim's `main` only holds the initial commit; the NCS toolchain provider is on the unmerged `claude/implement-spec` branch. Installed from `main` with lazy.nvim, nothing registers the NCS toolchain, so the Active toolchain is the Zephyr SDK (if one is found) or none.
2. **The Zephyr SDK is the Active toolchain.** With no toolchain chosen, `toolchain.active()` takes the first one listed, and the Zephyr SDK provider is listed before the NCS one. The Zephyr SDK's environment only sets `ZEPHYR_TOOLCHAIN_VARIANT` and `ZEPHYR_SDK_INSTALL_DIR`, not `PATH` or Python, so host CMake and host Python are used.
3. **The NCS toolchain's environment came back empty.** `nrf.toolchain.env()` returns nothing when `nrfutil` is missing from Neovim's `PATH`, when the call fails or takes over 15 s, or when the selector is wrong for a fork (`--ncs-version` from the bundle list vs. `--toolchain-bundle-id b77d8c1312`). A failure is silent: the build just runs with Neovim's own environment.
4. **The environment is incomplete.** `parse_env()` only reads `export VAR=value` lines. If `nrfutil sdk-manager toolchain env --as-script sh` prints something else (for example `PATH` set with `${PATH:+...}` or on several lines), `PATH`, `PYTHONHOME` or `PYTHONPATH` could be missing or wrong.

To check next time:

- Which nrf-connect.nvim revision is installed, and does `:Zephyr sdk list` show an NCS toolchain marked `*`?
- `:lua =require("zephyr.toolchain").env(require("zephyr.workspace").find())` — is there a `PATH` with `.../toolchains/b77d8c1312/usr/local/bin` first, and `PYTHONHOME`/`PYTHONPATH`?
- Output of `nrfutil sdk-manager toolchain env --as-script sh --toolchain-bundle-id b77d8c1312` (and with `--ncs-version`).
- `grep CMAKE_MAKE_PROGRAM build/CMakeCache.txt`.

Questions for the grilling session:

- When no toolchain is chosen, which one should be active in an NCS Workspace: always an NCS toolchain over the Zephyr SDK, or whatever the Manifest's NCS version maps to?
- Should a build refuse to start (or warn loudly) when the Active toolchain's environment can't be resolved, instead of falling back to Neovim's environment?
- Should zephyr.nvim say which toolchain a build used, in the first line of the Output window?

## 2. Output windows stay open

What happens: the Output windows of `:Zephyr build` and `:Zephyr update` stay open as a split after the command finishes; there is no quick way to close them.

Where it comes from:

- `ui/output.lua` (build, flash) opens a reused `zephyr://build` scratch buffer in a 12-line bottom split and never closes it.
- `ui/update.lua` opens its own `zephyr://update/<topdir>` split, separate from `ui/output.lua`.
- Neither sets buffer-local keymaps.

Likely fix: give every Output window buffer-local `q` (and maybe `<Esc>`) to close it, and move `:Zephyr update` onto `ui/output.lua` so all of them behave the same.

Questions for the grilling session:

- Close on `q` only, on any key once the command has finished, or automatically on success (keeping it open on failure)?
- When quickfix opens because of errors, should the Output window close then?
- Should the Output window be a split, a float, or configurable?
- Does the RTT viewer terminal follow the same rule, or stay as it is?

## 3. Pristine build can't find the custom board

What happens: `:Zephyr build` works on the existing build directory, but `:Zephyr build pristine` fails because CMake cannot find the App's custom board.

What zephyr.nvim does: for a pristine build it runs `west build -d <dir> -b <board> -p always`, with `<board>` taken from `CACHED_BOARD` in the build's `CMakeCache.txt`. It passes no source directory (west reads it from the cache) and no CMake arguments. `-p always` wipes the build directory, so every setting that only lived in the old cache is gone.

Likely causes, most likely first:

1. **The board root was only in the old cache.** If the build directory was first configured by the nRF Connect VS Code extension or by hand with `-DBOARD_ROOT=...` (or `-- -DBOARD_ROOT`), the incremental build keeps working from the cache, but the pristine one starts without it. zephyr.nvim neither records nor re-passes `BOARD_ROOT` (or any other extra CMake argument).
2. **The board name is not the one that was used.** `CACHED_BOARD` may hold the fully-qualified HWMv2 name (for example `myboard/nrf5340/cpuapp/ns`) or a revision (`myboard@1.0.0`), which may not resolve the same way as the name first passed to `-b`.
3. **Sysbuild reads the board from the wrong cache.** For a sysbuild build the board and source directory are read from the top-level cache; if west picks up `share/sysbuild` as the source instead of the App, the App's `boards/` directory is not on the board root.
4. **The same toolchain problem as issue 1.** CMake runs board discovery with Python; with host Python instead of the toolchain's, board listing could fail in a way that looks like "board not found".

To check next time:

- The exact CMake error.
- Where the custom board lives: the App's `boards/`, a separate board root, or a Zephyr module with `board_root` in `zephyr/module.yml`.
- `grep -E 'BOARD|BOARD_ROOT|APP_DIR|APPLICATION_SOURCE_DIR' build/CMakeCache.txt` before the pristine build.
- How the build directory was first created (VS Code, terminal, `:Zephyr build new`).
- Whether `west build -d build -p always` from a toolchain shell works.

Questions for the grilling session:

- Should a Build configuration own its extra CMake arguments (board root, extra conf files, overlays, `-D` flags), like VS Code's build configurations do, so a pristine build can recreate it?
- Should the plugin know about board roots (a setting, or read from the Workspace) so `:Zephyr build new` also lists custom boards?

## 4. Sysbuild configure fails on Kconfig for a Build configuration made by zephyr.nvim

What happens: with a working toolchain, configuring the `vt_connect` image fails. The quickfix list shows:

```
vt-wockel-sdk/zephyr/CMakeLists.txt|952 warning| No SOURCES given to Zephyr library: drivers__charger
vt-wockel-sdk/zephyr/CMakeLists.txt|952 warning| No SOURCES given to Zephyr library: drivers__serial
vt-wockel-sdk/zephyr/CMakeLists.txt|952 warning| No SOURCES given to Zephyr library: ..__wockel__drivers__gpio
vt-wockel-sdk/zephyr/CMakeLists.txt|2133 warning| __ASSERT() statements are globally ENABLED
vt-wockel-sdk/zephyr/cmake/modules/kconfig.cmake|396 error| command failed with return code: 1
cmake/modules/sysbuild_extensions.cmake|514 error| CMake configure failed for Zephyr project: vt_connect
```

Building a Build configuration that the nRF Connect VS Code extension created works.

What the output tells us:

- `kconfig.cmake:396` is where CMake runs Kconfig to merge the config fragments. It failing means Kconfig rejected the configuration, for example an assignment to an undefined symbol, a value outside its range, or warnings turned into errors.
- The "No SOURCES given" warnings for drivers (including the Workspace's own `wockel` GPIO driver) say the Kconfig options that pull those sources in are off, which fits a configuration that is missing fragments.
- The quickfix list does not show the reason. Kconfig prints its message without a file and line (or in a form `build.parse()` doesn't match), so it is only in the Output window.
- `sysbuild_extensions.cmake` has no absolute path, so its quickfix item points at the wrong file.

Likely causes, most likely first:

1. **zephyr.nvim passes less than VS Code does.** `:Zephyr build new` only records a board; the first build runs `west build -d <dir> -b <board> <app>`. A VS Code build configuration usually also passes extra Kconfig fragments (`EXTRA_CONF_FILE`), devicetree overlays (`EXTRA_DTC_OVERLAY_FILE`), a non-default `prj_<name>.conf` (`CONF_FILE` or `FILE_SUFFIX`), snippets (`-S`), sysbuild settings (`SB_CONF_FILE`, `--sysbuild`), a board root, and an optimisation level. Any of those missing would leave Kconfig symbols unset or undefined.
2. **The custom board or module isn't found the same way.** If the board, or the module that defines the `wockel` drivers' Kconfig, is added through a board root or `ZEPHYR_EXTRA_MODULES` passed by VS Code, Kconfig sees an assignment to a symbol that doesn't exist (same root as issue 3).
3. **A different board name.** VS Code may have configured with a fully-qualified HWMv2 target (`board/soc/cpu`) or a revision, while the one picked from `west boards` (or typed in) differs, so the board-specific `.conf` fragments don't apply.

To check next time:

- The Kconfig message just before the `kconfig.cmake` error in the Output window.
- Diff the CMake cache of the VS Code build directory against ours: `grep -E 'BOARD|CONF_FILE|OVERLAY|SNIPPET|BOARD_ROOT|EXTRA_MODULES|FILE_SUFFIX|SB_' build*/CMakeCache.txt build*/vt_connect/CMakeCache.txt`.
- `build_info.yml` in the VS Code build directory (Zephyr 3.7+ records the board and CMake arguments there).
- The build configuration in the VS Code workspace settings, if it is stored there.

Questions for the grilling session:

- Should a Build configuration hold everything VS Code's does (conf files, overlays, snippets, sysbuild on/off, board root, extra CMake arguments), and is VS Code's build configuration the model to copy?
- Should zephyr.nvim be able to import a VS Code build configuration, or is reading its build directory enough?
- Should Kconfig and sysbuild failures without a location still appear in quickfix, as an item without a file?

## 5. A Build configuration can't be edited after it is created

What happens: once `:Zephyr build new` has made a Build configuration, there is no way to change it (board, conf files, overlays, and so on).

Where it comes from: `build_config.new()` takes only a board (and a directory), and the Build configuration is otherwise read back from the CMake cache. There is no `edit` action in `:Zephyr build`, and nothing stores settings for a Build configuration apart from the board of one not yet built.

Questions for the grilling session:

- What should be editable: the board, conf files, overlays, snippets, sysbuild, extra CMake arguments, the build directory name?
- Where does an edit live before the next build: in plugin state, or straight in the build directory (which means a pristine build to apply most changes)?
- Should editing a Build configuration trigger a pristine build automatically, ask, or wait for the next `:Zephyr build pristine`?
- Edit through a sequence of pickers and prompts, or by opening a small editable buffer (like a form)?
- Can you edit a Build configuration that VS Code created, and must the result still work in VS Code?

## 6. Link a Build configuration to both a Zephyr version and an NCS version

What Joep asked: a Build configuration should link both the Zephyr version and the NCS version; today it only links the NCS one.

How it works now: the glossary says the NCS version is whatever the Workspace's Manifest pins, and the Active toolchain is chosen per Workspace, not per Build configuration. A Build configuration only records its board and what CMake cached. So nothing is linked to a Build configuration today; "only the NCS one" probably refers to `:Zephyr sdk select` listing only NCS toolchains.

This conflicts with the current model, so it needs settling before any code:

- Which "Zephyr version" is meant: the Zephyr revision in the Workspace (set by the Manifest), or the Zephyr SDK version (the Toolchain)?
- Which "NCS version" is meant: the NCS revision the Manifest pins, or the NCS toolchain?
- Should the Active toolchain move from the Workspace to the Build configuration, so two Build configurations of one App can use different toolchains?
- If a Build configuration names a Zephyr or NCS revision that differs from what the Manifest pins, is that Drift, an error, or a reason to switch Workspace?
- With an NCS fork, is the Zephyr SDK ever used, or always the NCS toolchain?
