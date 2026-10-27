# Spec: architecture clean-up

From the architecture review of 2026-10-27 (candidates 1, 2 and 3). Terms are from [CONTEXT.md](../../CONTEXT.md); the design rules (KISS, YAGNI, DRY, deep modules) are in [CLAUDE.md](../../CLAUDE.md). Nothing here changes what a user sees, except where it says so.

## Goals

- Each piece of knowledge lives in one module: how a setting becomes a `west build` argument, how a west command is run and stopped, how a file is read.
- Adding a Build configuration setting is one table row, not edits in six places.
- Build, flash and update share one way of running a west command, so a fix to stopping or output lands once.
- Leftovers from earlier versions are gone.

## Non-goals

- No new features, commands, settings or events.
- The public API that nrf-connect.nvim and other UIs use stays the same: `build_config.active`, `build_config.list`, `build.run`, `build.stop`, `build.is_running`, `flash.run`, `flash.stop`, `flash.is_running`, `update.run`, `process.run`, and every `User Zephyr*` event with its `ev.data`. The exception is the field renames on `zephyr.BuildConfig` in part 1 (nrf-connect.nvim doesn't use those fields).
- Splitting `build_config.lua` into more modules (review candidate 5) and resolving the Workspace once (candidate 4) are left out. Revisit them after part 1.

Order: part 3 first (small, no behaviour change), then part 1, then part 2. Each part is a few tickets, and every ticket ends with `make test` green on Neovim 0.10 and stable.

## 1. One field table for Build configuration settings

### Problem

The mapping "settings field ⇄ CMake variable / west flag" is written out in six places:

| Where | What it does with the mapping |
| --- | --- |
| `settings.reconfigure_fields`, `settings.list_fields` | which fields need a reconfigure, which are lists |
| `build.command` | settings → `west build` arguments |
| `build_config.parse_west_command` + `covered` | `west build` command line → settings |
| `build_config.settings_from_disk` | CMake cache + `build_info.yml` → settings |
| `build_config.from_settings`, `differences` | settings vs. what the build directory records |
| `ui/build_form` `M.fields`, `list_fields` | which fields the edit buffer shows, and how |

They already disagree. Settings call `EXTRA_DTC_OVERLAY_FILE` `overlays`, while `zephyr.BuildConfig` calls the same variable `extra_overlays` and uses `overlays` for `DTC_OVERLAY_FILE`. The form treats `cmake_args` as a scalar while settings treat it as a list.

### Design

`settings.lua` owns one ordered table, `settings.fields`. Each row describes one field:

| Key | Meaning |
| --- | --- |
| `name` | settings field, e.g. `"overlays"` |
| `kind` | `"string"`, `"list"`, `"bool"` or `"toolchain"` |
| `cmake` | the CMake cache variable it is read from and passed as, e.g. `"EXTRA_DTC_OVERLAY_FILE"`; nil for fields that are flags |
| `aliases` | older cache variables that mean the same, e.g. `OVERLAY_CONFIG` for `EXTRA_CONF_FILE` |
| `paths` | `"app"` or `"topdir"` when values are paths relative to that directory; nil otherwise |
| `reconfigure` | true when a change needs CMake to configure again |

Board, `-S` snippets, `--sysbuild`, the optimisation level and the Toolchain don't fit `-DVAR=value`. They keep small, named special cases in the one place that builds the command, and their rows say so (`cmake = nil`).

Everything listed in the table above loops over `settings.fields` instead of naming fields:

- `settings.normalize` gets the list fields and defaults from `kind`.
- `build.command` adds a `-D<cmake>=<joined absolute paths>` argument for each list row with a `cmake` variable, in table order.
- `parse_west_command` skips the `-D` variables of the rows (and their aliases), which replaces `covered`.
- `settings_from_disk`, `from_settings` and `differences` read and compare each row the same way.
- `needs_reconfigure` checks the rows with `reconfigure = true`.
- The edit buffer shows the rows in table order and treats `kind = "list"` as a list. This fixes `cmake_args`.

`zephyr.BuildConfig` names fields after the settings fields: `overlays` means `EXTRA_DTC_OVERLAY_FILE` everywhere. The `DTC_OVERLAY_FILE` value that a build directory records moves to `base_overlays` (only import and tests read it).

### Tests

- One round-trip test per row: settings → `build.command` → `parse_west_command` / cache fixture → `settings_from_disk` gives the same settings.
- The existing `build_spec`, `build_config_spec`, `import_spec` and `ui_build_form_spec` keep passing, apart from the `overlays` / `extra_overlays` rename.

## 2. One Job runner for west commands

### Problem

`build.run` and `flash.run` are near copies of each other:

- a `running` table keyed by build directory, with `is_running` and `stop`
- output capture and `on_output`
- start time and duration
- the "west could not be started" fallback
- the `ok` formula
- the Started and Finished events

`update.run` does the same again with its own line splitter, although `process.run` already splits lines. The Default UI repeats it a fourth time: `ui/build`, `ui/flash` and `ui/update` each wire `on_start`, `on_output` and `on_exit` to the Output window and format `[done in 1.2s]`.

### Design

A new module `zephyr.job` runs one west command as a **Job** (new CONTEXT.md term). Its interface:

```lua
-- Start `cmd`. `key` identifies the Job (a build directory, or a Workspace topdir for update);
-- only one Job per kind and key runs at a time.
job.start(kind, key, cmd, {
  cwd = ..., env = ...,
  event = "Build",            -- fires Zephyr<event>Started / Zephyr<event>Finished
  data = { ... },             -- merged into both events' ev.data
  on_start = fun(info), on_output = fun(line, stream), on_exit = fun(result),
}) --> started: boolean, err: string|nil

job.is_running(kind, key) --> boolean
job.stop(kind, key)       --> boolean   -- on_exit still runs, with stopped = true
```

`result` holds `ok`, `code`, `stopped`, `duration` and `output` (every line). `job` uses `process.run` with `group = true`, so stopping also stops the tools west starts (cmake, ninja, the flash runner).

Each component keeps only what is its own:

- `build`: the command, the Toolchain environment, Pristine-next, the Active app, and parsing `result.output` into quickfix `items`.
- `flash`: the command, the runner and the Probe.
- `update`: the command. Its `{ stop = fun() }` handle becomes a thin wrapper over `job.stop`.

Their public functions (`run`, `stop`, `is_running`, `update.run`'s handle) and their events stay as they are.

In the Default UI, `ui/output` gets a `follow(name, opts)` helper that returns `on_start`, `on_output` and `on_exit` callbacks. They open the Output window with the Toolchain and command as its title, append lines, and on exit write the `[done|failed|stopped in N s]` line and wire `q` to stop. `ui/build`, `ui/flash` and `ui/update` use it and keep only their own notifications and quickfix handling.

RTT stays as it is: its viewer is a terminal job, not a streamed Job.

### Tests

- New `job_spec`: start, output lines, stop while running, a command that can't start, and one Job per key. `process.run` is stubbed, as in the other specs.
- The stop and exit cases in `build_spec`, `flash_spec` and `update_spec` that only test the copied plumbing move to `job_spec`. The specs keep their command and event tests.

## 3. Clean-up: leftovers and copies

No behaviour change.

1. **`state.lua`**: a bad merge (720a6e0) left a second `M.unset` defined inside `M.get`. Remove it so `get` only reads.
2. **File reading**: add `zephyr.fs` with `read(path) -> string|nil` and `is_dir(path) -> boolean`. Use them in place of the hand-written readers in:
   - `build_config`, `clangd`, `rtt` (each has its own `read_file`)
   - `flash`, `sdk` (twice), `manifest`, `workspace`, `app`, `settings`, `state` and `yaml`

   Writes stay where they are.
3. **Subcommand actions**: each `ui/*.lua` keeps its `M.actions`. `commands.lua` completes from those (looking up the UI module when completing) instead of keeping its own copy, and checks the action once before calling the subcommand. The four copies of "unknown action '%s'; use …" in the UI modules go. Drop the unused `impl == false` "not implemented yet" path.
4. **`notify`**: the eight `local function notify` copies in `ui/` become one `require("zephyr.ui.notify")`, with the same "zephyr: " prefix.
5. **Migrations**: remove the two upgrade paths from versions before the settings file, and their tests:
   - the old personal-state Build configuration in `build_config.active`
   - the per-Workspace Toolchain (`toolchain.migrate`)

   Only do this after Joep has opened each Workspace once with the current version (see open questions).

## Open questions

- Part 3.5: have all of Joep's Workspaces been opened with the current version, so the migrations have run? If not, keep them one more release.
- Part 1: is renaming `zephyr.BuildConfig.overlays` / `extra_overlays` acceptable, or should the old names stay as aliases for one release? nrf-connect.nvim doesn't read them.
- Part 2: should the Job `kind`/`key` pair be one string (e.g. `"build:" .. dir`)? A pair keeps `is_running` readable; a string is simpler.
