# Spec: refinements after first real use

Draft, filled in as the grilling of [known issues](../known-issues.md) goes. Terms are from [CONTEXT.md](../../CONTEXT.md).

## Decided (2026-10-27, round 1)

1. **A Build configuration owns its settings.** Like the nRF Connect VS Code extension's build configurations, it holds: board, config files, extra Kconfig fragments, devicetree overlays, snippets, sysbuild on/off, optimisation level, board roots, extra CMake arguments and its Toolchain. zephyr.nvim stores these itself, so a Pristine build or an edit can recreate the build directory from scratch (known issues 3, 4, 5).
2. **Versions mean Toolchains.** "Zephyr version" and "NCS version" on a Build configuration are its Toolchain (Zephyr SDK or NCS toolchain). Source revisions stay owned by the Workspace's Manifest. The Active toolchain moves from the Workspace to the Build configuration (issue 6).
3. **Default Toolchain.** With none chosen: the NCS toolchain matching the NCS version the Manifest pins; else the newest NCS toolchain; the Zephyr SDK only when no NCS toolchain is installed. If the Toolchain's environment can't be resolved, the build does not start and says why (issue 1).
4. **Output windows close.** While a command runs, `q` stops it and closes the Output window. Once it has finished, any key closes it. Build, flash and update share one Output window (issue 2).
5. **VS Code interop is one-way.** zephyr.nvim imports VS Code-made Build configurations by reading the build directory (CMake cache, `build_info.yml`) into its settings, and never writes VS Code settings (issue 4).
6. **Kconfig and sysbuild failures reach quickfix**, as entries without a file when they have no location, first in the list (issue 4).

## Decided (2026-10-27, round 2)

7. **Settings live in the Workspace, ignored by git.** The Build configuration settings are a file inside the project that git ignores without the team having to change anything. Which Build configuration is active stays personal state.
8. **Build and flash work from above the App.** A Manifest often exports shared files next to the App (`workspace/app/west.yml` exports `workspace/nrflib`, `workspace/scripts`), so `:Zephyr build` and `:Zephyr flash` must work from files outside the App.
9. **Settings win** over what a build directory was configured with; `:Zephyr build` warns about the difference and offers a Pristine build.
10. **Editing is an editable buffer** with completion and pickers for fields; `:Zephyr build new` opens the same buffer pre-filled.
11. **Applying an edit asks.** An edit that needs a reconfigure asks whether to do a Pristine build; an option makes the next build pristine without asking.
12. **`:Zephyr sdk select` sets the Active toolchain of the active Build configuration**; flash, RTT and clangd's `--query-driver` follow it. No per-Workspace choice is left. The first Output window line names the Toolchain used.
13. **Only `q` closes the Output window**: while running it stops the command and closes; once finished it closes. Other keys keep working for scrolling.
14. **VS Code Build configurations are imported automatically** the first time a build directory without settings is seen, with a notification.
15. **Board roots come from Zephyr and the Workspace.** Besides what Zephyr finds itself (the App's `boards/`, module board roots), zephyr.nvim checks the Workspace's `boards/` directory.

## Open

Round 3: settings file location and format, the active App for builds from outside an App, board root detection details, edit buffer layout, the pristine prompt, a Toolchain that is not installed on this machine, migrating per-Workspace Toolchain choices.
