# aqueousctl command reference

Reference for the current Aqueous source tree. Run commands inside an Aqueous
session, using its `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` environment.

Commands below are individual examples, not a script to execute in sequence.
Replace `WINDOW_ID`, `WORKSPACE_ID`, `GROUP_ID`, `OUTPUT`, and `SEAT` with actual
values. Quote names containing spaces. Optional syntax is written `[like this]`;
do not type the brackets.

## Command summary

```text
aqueousctl windows [--json]
aqueousctl inspect --rule
aqueousctl scene [--dot]
aqueousctl outputs [--json]
aqueousctl input devices --json
aqueousctl input generate-config --device DEVICE_ID --id RULE_ID (--output OUTPUT|--mapping desktop|--disabled) [--write PATH]
aqueousctl overlay-planes [--json]

aqueousctl layout --output OUTPUT --json
aqueousctl layout --output OUTPUT --set LAYOUT --json

aqueousctl cursor [--json]
aqueousctl cursor set --theme THEME --size SIZE [--json]

aqueousctl shell capabilities --json
aqueousctl shell snapshot --json
aqueousctl shell watch --json

aqueousctl window activate --id WINDOW_ID [--seat SEAT] --json
aqueousctl window close --id WINDOW_ID --json
aqueousctl window state --id WINDOW_ID --minimized true|false --json
aqueousctl window state --id WINDOW_ID --maximized true|false --json
aqueousctl window state --id WINDOW_ID --fullscreen true|false --json
aqueousctl window move --id WINDOW_ID --workspace-id WORKSPACE_ID --json
aqueousctl window move --id WINDOW_ID --output OUTPUT --json

aqueousctl workspace activate --id WORKSPACE_ID [--seat SEAT] --json
aqueousctl workspace rename --id WORKSPACE_ID --name NAME --json

aqueousctl keyboard query --json
aqueousctl keyboard set [--seat SEAT] [--group GROUP_ID] --index INDEX --json
aqueousctl keyboard next [--seat SEAT] [--group GROUP_ID] --json

aqueousctl overview show --output OUTPUT --json
aqueousctl overview hide --json
aqueousctl overview toggle --output OUTPUT --json

aqueousctl session reload --json
aqueousctl session exit --json
```

`true|false` means choose exactly one value. Keep the displayed argument order
for `layout` and `cursor`; their parsers require it. Shell command families
(`shell`, `window`, `workspace`, `keyboard`, `overview`, `session`) require
`--json`. `scene` supports `--dot`, not `--json`.

## Inspect windows and generate rules

```sh
aqueousctl windows
aqueousctl windows --json
aqueousctl inspect --rule
```

Window inspection includes IDs, backend, application identity, title, output,
workspace number, geometry, layout, content type, client-provided tag and
description, and states. Tag and description are null when unset (including
XWayland), and empty strings when explicitly set empty. JSON also includes
decoration information and the matched rule index.

`inspect --rule` prints a TOML rule entry for each mapped window: `app_id` for
native Wayland applications and `class` for XWayland. Native windows with a
non-empty tag also get a literal `tag` matcher, with TOML and glob escaping.
Titles are included as
commented optional matchers. Copy the entries you need into `rules.toml`.

## Inspect outputs, rendering, and the scene graph

```sh
aqueousctl outputs
aqueousctl outputs --json
aqueousctl overlay-planes
aqueousctl overlay-planes --json
aqueousctl scene
aqueousctl scene --dot
```

`outputs` lists connector names, display identity, advertised modes, enabled
state, position, scale, transform, and adaptive sync. It is an inspection
command; it has no output-configuration options.

`overlay-planes` reports DRM overlay promotion capability, phase, rejection
reason, candidate details, retry backoff, and promotion/fallback counters.

`scene` prints the compositor scene tree. To render DOT output with Graphviz:

```sh
aqueousctl scene --dot | dot -Tsvg -o aqueous-scene.svg
```

## Change workspace layout

```sh
aqueousctl layout --output DP-1 --json
aqueousctl layout --output DP-1 --set scrolling --json
aqueousctl layout --output DP-1 --set tile --json
```

The target is the named output's active workspace. Changes are runtime
overrides and do not edit configuration files.

Supported layout names:

```text
tile
monocle
grid
rows
dwindle
reverse-dwindle
scrolling
float
game-mode
composable
```

Aliases: `floating`, `stack`, and `stacking` mean `float`;
`reverse_dwindle` means `reverse-dwindle`; `game_mode` means `game-mode`.

## Inspect and change the cursor

```sh
aqueousctl cursor
aqueousctl cursor --json
aqueousctl cursor set --theme default --size 24
aqueousctl cursor set --theme Bibata-Modern-Ice --size 32 --json
```

Both `--theme` and `--size` are required when setting the cursor. Size must be
an integer from 1 through 512; use an installed Xcursor theme.

This updates compositor cursors on every seat, XWayland default cursors, and
the cursor environment inherited by applications subsequently launched by
Aqueous. Native clients can supply their own cursors. Persist the preference
separately if it should survive a new session; this command does not rewrite
configuration or other processes' activation environments.

## Discover shell state and runtime IDs

```sh
aqueousctl shell capabilities --json
aqueousctl shell snapshot --json
aqueousctl shell watch --json
```

- `capabilities` reports the schema and available features.
- `snapshot` returns one atomic state snapshot.
- `watch` emits an initial snapshot followed by updates as newline-delimited
  JSON. Stop the watcher with Ctrl+C.

Records cover windows, outputs, workspaces, seats, keyboard groups/devices,
and the session. IDs are strings scoped to the current compositor session.
Obtain fresh IDs after restarting Aqueous.

Window IDs come from `windows --json` or shell window records. Workspace and
keyboard group IDs come from shell records. A workspace ID is different from
its display number or name. Commands taking `--output` use the connector name,
such as `DP-1`, rather than a shell output ID.

These read-only examples require `jq`:

```sh
# Window IDs, application IDs, titles, and current state.
aqueousctl windows --json | jq '.[] | {id, app_id, title, states}'

# Workspace IDs, names, display numbers, and owning output IDs.
aqueousctl shell snapshot --json | jq '.upsert[] | select(.kind == "workspace")'

# Map output IDs to connector names.
aqueousctl shell snapshot --json | jq '.upsert[] | select(.kind == "output")'

# Seat names and focused windows.
aqueousctl shell snapshot --json | jq '.upsert[] | select(.kind == "seat")'

# Keyboard group IDs, layouts, and active indices.
aqueousctl keyboard query --json | jq '.upsert[] | select(.kind == "keyboard")'
```

## Activate and close windows

```sh
aqueousctl window activate --id "WINDOW_ID" --json
aqueousctl window activate --id "WINDOW_ID" --seat default --json
aqueousctl window close --id "WINDOW_ID" --json
```

Activation reveals the window's workspace and restores a minimized window.
Integrated dialog policy can direct parent activation to an eligible modal
dialog. Focus restrictions still apply.

Close requests client cooperation; success means the request was accepted,
not that the application has finished exiting. Close does not accept `--seat`.

## Minimize, maximize, and fullscreen

```sh
aqueousctl window state --id "WINDOW_ID" --minimized true --json
aqueousctl window state --id "WINDOW_ID" --minimized false --json

aqueousctl window state --id "WINDOW_ID" --maximized true --json
aqueousctl window state --id "WINDOW_ID" --maximized false --json

aqueousctl window state --id "WINDOW_ID" --fullscreen true --json
aqueousctl window state --id "WINDOW_ID" --fullscreen false --json
```

Set exactly one state per invocation. Use explicit `true` or `false`; there is
no toggle value. Minimize/maximize eligibility follows floating-window policy;
unsupported transitions return an error. Shell window records expose
`can_minimize`, `can_maximize`, and `can_activate` for UI consumers.

## Move windows

```sh
aqueousctl window move --id "WINDOW_ID" --workspace-id "WORKSPACE_ID" --json
aqueousctl window move --id "WINDOW_ID" --output DP-2 --json
```

Choose exactly one destination. An output destination means that output's
active workspace. Moving does not request workspace activation or focus
following. These commands do not accept pixel coordinates or dimensions.

## Activate and rename workspaces

```sh
aqueousctl workspace activate --id "WORKSPACE_ID" --json
aqueousctl workspace activate --id "WORKSPACE_ID" --seat default --json
aqueousctl workspace rename --id "WORKSPACE_ID" --name "Development" --json
```

Activation also selects the workspace's output for the seat, including when
the workspace is empty. Rename changes its display name without changing its
runtime ID. Rename does not accept `--seat`; the name must be nonempty UTF-8
without a newline.

## Control keyboard layouts

```sh
aqueousctl keyboard query --json

aqueousctl keyboard set --index 0 --json
aqueousctl keyboard set --seat default --index 1 --json
aqueousctl keyboard set --seat default --group "GROUP_ID" --index 0 --json

aqueousctl keyboard next --json
aqueousctl keyboard next --seat default --group "GROUP_ID" --json
```

`query` returns the complete shell snapshot and accepts no extra options.
Layout indices are zero-based and must exist in the group's configured layout
list. `next` wraps to the first layout. Without `--group`, control applies to
the selected seat's active keyboard group. An explicit group must belong to
that seat. Changes affect live XKB state and do not rewrite keyboard config.

## Control the overview

```sh
aqueousctl overview show --output DP-1 --json
aqueousctl overview toggle --output DP-1 --json
aqueousctl overview hide --json
```

Show and toggle require an output name. Hide takes no output. Repeated show
and hide requests are idempotent.

## Reload configuration or end the session

```sh
aqueousctl session reload --json
```

Reloads through Aqueous's normal configuration path, including rules, input,
output policy, and configured reload commands. Startup-only options still
require restarting the compositor. This command requires shell manager
version 2; check the `config_reload` capability if supporting older builds.

```sh
aqueousctl session exit --json
```

Ends the Aqueous session through orderly compositor termination after an
accepted acknowledgement.

## Results and scripting rules

For shell commands requiring a seat, `--seat` may be omitted only when exactly
one seat exists. With multiple seats, pass the name explicitly.

Shell mutations require integrated internal policy and an unlocked session;
external/comparison policy rejects them. State inspection remains available
subject to protocol capabilities and client access restrictions. Sandboxed
Wayland security-context clients cannot access the privileged control globals.

Shell command results contain `ok`, `status`, and `sequence`. Status values:

| Status | Meaning |
|---|---|
| `applied` | The operation was applied. |
| `accepted` | The request was accepted; completion may be asynchronous. |
| `invalid` | A value or operation is invalid. |
| `not_found` | The requested target, seat, or group was not found. |
| `locked` | The session is locked. |
| `unsupported` | The operation is unsupported by the current policy or target. |
| `busy` | The compositor cannot accept the operation now. |
| `ambiguous_seat` | An explicit seat is required. |
| `unavailable` | The target or required state is unavailable. |

Exit codes are `0` for success, `1` for operation/transport failure, and `2` for
malformed command-line arguments. Parse JSON and check the process exit code.
Layout and cursor commands have their own result fields/statuses; they do not
use the shell result schema.

Shell initial state and command requests have a five-second deadline. An
established watch has no idle timeout. A timed-out mutation may have executed:
inspect fresh state before deciding whether to retry it.

When consuming watch updates, apply each batch atomically, check that
`base_sequence` matches the previously accepted sequence, and replace the
local model with a fresh snapshot after reconnecting.

## Scope

This lists aqueousctl's user-facing command forms. There is no generic action
dispatcher, arbitrary window move/resize command, output mode setter, or
shell-command launcher in this CLI. Use Aqueous configuration and its settings
application for controls outside this command set.

## Configure tablets

```sh
aqueousctl input devices --json
aqueousctl input generate-config --device DEVICE_ID --id kamvas-pen --output OUTPUT
aqueousctl input generate-config --device DEVICE_ID --id kamvas-pen --output OUTPUT --write ~/.config/aqueous/input.toml
```

Discovery reports connected input devices, their session IDs and persistent
identity fields, available outputs, the selected input sidecar, and each tablet's
mapping status. Use a tablet's `id` only to select it in this session; generated
rules contain persistent selectors. Generation requires internal-policy mode.

Exactly one of `--output OUTPUT`, `--mapping desktop`, or `--disabled` is required.
By default the command prints a TOML rule and changes no files. `--write PATH`
atomically updates the selected rule by `--id`, preserving unrelated settings,
comments, permissions and existing symlinks. The parent directory must exist.
Malformed or unsupported existing TOML, ambiguous device identities, unavailable
outputs, and detected concurrent file changes are errors. No full reload is sent;
the configuration watcher applies active-sidecar writes. Check discovery again to
confirm the result; `pending: true` means the pen must leave proximity first.

See [Tablet configuration](tablet-configuration.md) for HUION/Wacom setup,
matching and sidecar precedence, desktop/disabled rules, and troubleshooting.
