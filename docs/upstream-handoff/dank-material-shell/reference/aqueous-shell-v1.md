# Aqueous shell protocol, version 1

The MIT-licensed [Wayland XML](aqueous-shell-v1.xml) and
[JSON schema](aqueous-shell-v1.schema.json) describe the shell interface.
`aqueousctl` is the supported command/stream adapter. There is no separate
compositor socket or external window-manager connection to configure.

## Discovery and compatibility

Bind `aqueous_shell_manager_v1` on the current Wayland display. Its capabilities
JSON includes `schema: 1`, a random 128-bit session token, maximum batch size,
and independent `state`, `commands`, `keyboard`, `overview` and
`shortcut_inhibition` booleans. The token changes on compositor restart.
Commands/keyboard control/overview control require integrated internal policy;
external and comparison diagnostic modes expose observation only. Locked
sessions remain observable to trusted shell clients but reject every mutation.
The shell global is hidden from Wayland security-context clients. Shortcut
inhibition is available to ordinary application surfaces, scoped to focus/seat.

Use capability discovery rather than assuming that installing `aqueousctl`
means the running compositor supports this protocol. Schema 1 permits additive
fields. Ignore unknown optional fields; reject unsupported schema versions.

```sh
aqueousctl shell capabilities --json
aqueousctl shell snapshot --json
aqueousctl shell watch --json
```

The first command prints capabilities, the second prints one complete snapshot,
and the third prints a snapshot followed by deltas, one JSON object per line.
The CLI allows five seconds for connection/initial state or command completion.
An established watch has no idle timeout, heartbeat or polling subprocess.
Malformed/truncated input or a broken sequence terminates the CLI with a nonzero
exit code. A consumer restarts it with bounded backoff and replaces its old model
with the new snapshot. Do not automatically retry a timed-out mutation: it may
already have executed; inspect fresh state first.

## Identity and entities

All IDs and sequences are JSON strings. IDs are scoped to the session token;
never interpret them as pointers, indices or persistent configuration keys.
Window IDs are the exact `ext_foreign_toplevel_handle_v1.identifier` values.
Output, workspace, keyboard group and keyboard device IDs are monotonically
allocated runtime identities. Seats use their names. Removal/recreation gives
outputs/devices/groups new IDs even if their names are reused.

Workspace identity survives rename, renumbering and output migration while the
workspace exists. `number` is a one-based display position. The optional
ext-workspace persistent ID remains absent: Aqueous does not promise identity
across sessions. Native Wayland clients can send `identify_workspace` with their
own ext-workspace handle and receive the corresponding runtime ID; removed
handles return an empty string.

| Kind | Principal fields |
| --- | --- |
| `output` | `id`, connector `name`, `enabled`, `powered`, `bounds`, `usable_bounds`, `scale`, `transform`, `active_workspace` |
| `workspace` | `id`, `output`, `name`, `number`, `active`, `urgent` |
| `window` | `id`, `backend`, `app_id`, `class`, `title`, `workspace`, `output`, `geometry`, `outer_geometry`, presentation/visibility flags and per-window capabilities |
| `seat` | name as `id`, selected `output`, focused `window`, `focus_kind`, active `keyboard` group |
| `keyboard` | group `id`, `seat`, layout names in `layouts`, zero-based effective `index` |
| `keyboard_device` | `id`, `name`, `seat`, `group`, `virtual` |
| `session` | fixed `id: "session"`, `locked`, unambiguous `default_seat`, `overview_output`, `overview_window` |

Cleared optional values are `null`. Full entity replacements are sent on change;
missing optional values must not preserve an earlier value. Backend `xwayland`
uses `class` for application identity when `app_id` is null.

`enabled` includes temporarily powered-off outputs; `powered` reports whether
the output is currently on. `can_activate` reflects focus eligibility.

`visible` means mapped on an active workspace and not policy-hidden, not that
pixels are unoccluded. `can_minimize` and `can_maximize` describe eligibility for
client requests in floating presentations; tiled layouts generally reject these
requests. A compositor-owned maximize may not be undone by a client request.
`focused` means focused by at least one seat; consult the seat entities for the
specific seat. Selected output is independent of window focus and persists while
layer-shell surfaces have focus. No keyboard or ambiguous seat defaults use null.

## Geometry and capture

`geometry` is the committed global logical content box (`Window.box` after a
render transaction). Negative coordinates are valid. `outer_geometry` adds the
compositor-owned enabled border edges; it does not invent client shadow extents.
Client-side decorations included in the client's content geometry remain there.
Fullscreen suppresses compositor borders.

During movement animations these boxes describe the committed destination. The
compositor's frozen visual clone may still be moving. Per-frame clone geometry
is intentionally not streamed; there is no animation timer or rendered-pixel
claim in this interface. A screenshot consumer must choose composed-output crop
versus isolated toplevel capture explicitly. Output crop includes occluders.
For a crop, subtract output logical origin, apply scale and output transform,
round crop edges outward, and intersect with the output pixel extent. Do not
assume an unrotated scale-1 origin or include another workspace's hidden window.
Use existing wlr output management for full modes/transform information and
standard capture protocols for pixels.

## Atomic batches and flow control

`subscribe` is allowed once per manager. The server sends `begin(serial)`, one
or more `data(bytes)` fragments, then `done(serial)`. Concatenate fragments before
UTF-8 decoding and JSON parsing: fragment boundaries can split codepoints.
Maximum complete JSON size is 4 MiB. Entity state is limited to 2 MiB including
accounting overhead. A compositor permits at most 16 bound shell managers.

A complete batch has this envelope (the entity list below is abbreviated):

```json
{"schema":1,"session":"6b94a179d09456846b94a179d0945684","sequence":"12","base_sequence":null,"type":"snapshot","upsert":[{"kind":"workspace","id":"7","output":"2","name":"Code","number":1,"active":true,"urgent":false}],"removed":[]}
```

Deltas contain changed full entities and removal keys in `kind:id` form:

```json
{"schema":1,"session":"6b94a179d09456846b94a179d0945684","sequence":"15","base_sequence":"12","type":"delta","upsert":[{"kind":"workspace","id":"7","output":"2","name":"Review","number":1,"active":true,"urgent":false}],"removed":["window:closed-window-id"]}
```

Apply all replacements/removals atomically, regardless of their order in the
arrays. A real initial snapshot contains all current entities, including empty
workspaces and outputs. Two outputs may both have a workspace named `1`; use
runtime associations. A delta can move a workspace to a surviving output and
remove the old output in the same batch. A layer-focus delta clears the seat's
window but retains its selected output. After restart, discard all old IDs.

Acknowledge the exact `done` serial only after accepting the batch. One batch
can be in flight per manager. A slow consumer pauses delivery rather than
accumulating an unbounded queue. Changes meanwhile coalesce into the next delta
against the client's acknowledged baseline. Sequence numbers can jump;
`base_sequence` must exactly match the consumer's previous sequence. Duplicate
subscriptions or invalid acknowledgements are protocol errors. State size and
client limits fail explicitly rather than truncating data. A paused connection
is bounded; it is released normally on disconnect.

Publication is event-driven after policy/render transactions and workspace
publication settle. No repeating scan is scheduled. At each dirty publication
Aqueous constructs/diffs committed entity state; unchanged entities generate no
wire traffic. This favors a consistent whole-desktop transaction over per-field
invalidation caches. Future optimization can narrow reconstruction without
changing the wire contract.

## Typed commands

```sh
aqueousctl window activate --id ID [--seat SEAT] --json
aqueousctl window close --id ID --json
aqueousctl window state --id ID --minimized true --json
aqueousctl window state --id ID --maximized false --json
aqueousctl window state --id ID --fullscreen true --json
aqueousctl window move --id ID --workspace-id ID --json
aqueousctl window move --id ID --output CONNECTOR --json
aqueousctl workspace activate --id ID [--seat SEAT] --json
aqueousctl workspace rename --id ID --name NAME --json
aqueousctl keyboard query --json
aqueousctl keyboard set [--seat SEAT] [--group ID] --index 1 --json
aqueousctl keyboard next [--seat SEAT] [--group ID] --json
aqueousctl overview show --output CONNECTOR --json
aqueousctl overview hide --json
aqueousctl overview toggle --output CONNECTOR --json
aqueousctl session exit --json
```

Omit `--seat` only when exactly one seat exists; omit `--group` to target that
seat's active keyboard group. Keyboard query returns the complete atomic shell
snapshot, including keyboard groups, devices and seat associations. Group
indices are zero-based; next wraps. Switching changes live XKB state, not TOML.
Physical/client-origin layout changes and hotplug/reload produce normal deltas.

Moving by output selects its currently active workspace. Moving does not request
workspace activation or focus-following; ordinary policy repairs focus when the
source window becomes hidden. Activation reveals the target workspace and
restores eligible minimized windows. Move/state/activation cancels the existing
overview. Rename changes the display name without identity changes. Names are
UTF-8, at most 1024 bytes and cannot contain newline characters.

Overview is the existing compositor-owned modal overview. Show/hide are
idempotent. Show on a different output cancels the old overview first. Empty
workspaces or policy conditions that prohibit overview return `unavailable`.
The overview is global, and its output/selection is reported in the session
entity. Lock and normal compositor cancellation rules remain authoritative.

One outstanding command is allowed per manager. Requests are queued until a
settled transaction and their targets are resolved then, so disappearing objects
produce `not_found`. Pending command storage is bounded. Results contain the
request ID, status and current committed state sequence. `applied` is sent after
committing the operation. Close and exit return `accepted`: close requests do
not force a client to exit; session exit flushes its acknowledgement before
orderly compositor termination. EOF without that acknowledgement is an error.

The CLI prints `{ "ok": true, "status": "applied", "sequence": "15" }` or a
corresponding error object. Errors include `invalid`, `not_found`, `locked`,
`unsupported`, `busy`, `ambiguous_seat` and `unavailable`. JSON goes to stdout;
diagnostics go to stderr. Exit status is 0 on success, 2 for malformed CLI
arguments and 1 for protocol/operation failure. There is no arbitrary command
execution or public raw internal action dispatcher.

## Shortcut inhibition policy

The focused surface's inhibitor is active only for its seat, while unlocked and
outside compositor overview. Focus loss, client destruction and lock deactivate
it. Normal policy and external XKB bindings are bypassed while active. Built-in
VT switching remains reserved; inhibition does not disable secure session lock.
Each key release retains the consumer chosen for its press, including when the
inhibitor disappears between press and release. Existing XWayland grab policy
remains in place. Starting overview refreshes inhibitor eligibility immediately.

## Validation

`zig build test` includes CLI parsing and batch continuity checks. Run
`python3 scripts/test-shell-integration.py` with a Pixman-compatible diagnostic
compositor (or the binary overrides described by the test) for isolated two-output
state/actions, keyboard layout, inhibition, flow control, lock, and frame tests.
No test connects to the user's Wayland display. Hardware capture, DPMS and
suspend/resume remain desktop release checks; this protocol alone does not add
an upstream DMS consumer.
