# Spec: refinements after first real use

Draft, filled in as the grilling of [known issues](../known-issues.md) goes. Terms are from [CONTEXT.md](../../CONTEXT.md).

## Decided (2026-10-27, round 1)

1. **A Build configuration owns its settings.** Like the nRF Connect VS Code extension's build configurations, it holds: board, config files, extra Kconfig fragments, devicetree overlays, snippets, sysbuild on/off, optimisation level, board roots, extra CMake arguments and its Toolchain. zephyr.nvim stores these itself, so a Pristine build or an edit can recreate the build directory from scratch (known issues 3, 4, 5).
2. **Versions mean Toolchains.** "Zephyr version" and "NCS version" on a Build configuration are its Toolchain (Zephyr SDK or NCS toolchain). Source revisions stay owned by the Workspace's Manifest. The Active toolchain moves from the Workspace to the Build configuration (issue 6).
3. **Default Toolchain.** With none chosen: the NCS toolchain matching the NCS version the Manifest pins; else the newest NCS toolchain; the Zephyr SDK only when no NCS toolchain is installed. If the Toolchain's environment can't be resolved, the build does not start and says why (issue 1).
4. **Output windows close.** While a command runs, `q` stops it and closes the Output window. Once it has finished, any key closes it. Build, flash and update share one Output window (issue 2).
5. **VS Code interop is one-way.** zephyr.nvim imports VS Code-made Build configurations by reading the build directory (CMake cache, `build_info.yml`) into its settings, and never writes VS Code settings (issue 4).
6. **Kconfig and sysbuild failures reach quickfix**, as entries without a file when they have no location, first in the list (issue 4).

## Open

Round 2: where the settings are stored, settings vs. build directory conflicts, editing UI, applying edits, `:Zephyr sdk select` per Build configuration, which keys close a finished Output window, when VS Code imports happen, board roots.
