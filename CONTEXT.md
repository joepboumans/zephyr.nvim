# zephyr.nvim

Vendor-neutral Zephyr support for Neovim, exposed as a Lua API that UIs are built from.

## Language

**Workspace**:
A west workspace: a top directory holding the manifest repository and every project it pins, such as Zephyr and NCS.
_Avoid_: project folder, SDK folder

**Manifest**:
The west manifest of a Workspace; it is the single source of which revision each project should be on.
_Avoid_: west file, version file

**App**:
A Zephyr application directory that is built against exactly one Workspace.
_Avoid_: project, sample (unless it is one)

**Active app**:
The App of a Workspace that build and flash use when the current file is not inside an App; the one built last, or picked.
_Avoid_: current project, default app

**Build configuration**:
One way of building an App: its board, config files, overlays, snippets, sysbuild choice, board roots, extra CMake arguments and Toolchain, plus the build directory it produces; an App can have several, and one is active.
_Avoid_: build, target, build folder

**Pristine build**:
A build that wipes a Build configuration's directory and configures it again from scratch, so only what the Build configuration itself records survives.
_Avoid_: clean build, rebuild

**Board root**:
A directory that holds board definitions, searched in addition to Zephyr's own boards; custom boards are found through one.
_Avoid_: board dir, boards folder

**Drift**:
The state where a project checked out in the Workspace is not on the revision its Manifest names.
_Avoid_: out of date, mismatch

**Component**:
One self-contained part of the plugin's Lua API, such as build, flash or RTT, that UIs are assembled from.
_Avoid_: module (that means a Zephyr module), service

**Toolchain**:
The compilers and host tools an App is built with.
_Avoid_: SDK (unless it is the Zephyr SDK)

**Zephyr SDK**:
The vendor-neutral Toolchain published by the Zephyr project.

**Toolchain provider**:
A source of Toolchains that can be found, installed and activated; zephyr.nvim ships the Zephyr SDK provider and other plugins register more.
_Avoid_: toolchain plugin, backend

**Active toolchain**:
The Toolchain a Build configuration is built, flashed and indexed with; chosen per Build configuration, else a default picked from what is installed.
_Avoid_: current toolchain, selected SDK, workspace toolchain

**Probe**:
A debug adapter connected to a target board, identified by its serial number; only J-Link is supported.
_Avoid_: device, programmer, debugger

**Probe finder**:
A source of connected Probes; zephyr.nvim ships the J-Link finder and other plugins register more.
_Avoid_: probe backend, probe plugin

**Active probe**:
The Probe a Workspace flashes through, chosen once and remembered.
_Avoid_: current probe, selected device

**RTT viewer**:
A live view of a target's SEGGER RTT output, read through a Probe; by default the J-Link RTT client in a terminal.
_Avoid_: log window, serial terminal

**RTT stream**:
The RTT output as data that other UIs can consume to build their own RTT viewer.
_Avoid_: RTT log, RTT buffer

**Output window**:
The split of the Default UI that shows the streamed output of a build, flash or update.
_Avoid_: log window, terminal (unless it is the RTT viewer)

**Default UI**:
The commands and pickers shipped with the plugin, built only on the public API.
_Avoid_: frontend, the plugin

## Project rules

**No CI**:
This repo has no hosted CI (no GitHub Actions or similar), because it costs money and isn't needed. Run `make test` locally before merging. Don't add CI workflows back.
