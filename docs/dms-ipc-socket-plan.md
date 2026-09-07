# DMS: replace Aqueous subprocess transport with persistent IPC

Status: proposed implementation plan, 2026-09-06.

This file is a standalone handoff. Copy it into the DMS repository, for example
as `docs/aqueous-ipc-socket-plan.md`. It contains the implemented runtime wire contract,
implementation tasks and acceptance criteria; no sibling Aqueous plan is needed.
The socket is implemented in the Aqueous source tree; use a newly built
compositor and check hello rather than assuming installed binaries support it.

## Objective and delivery boundary

Use persistent Unix socket connections for Aqueous discovery, state events and
runtime commands. Eliminate the per-command aqueousctl processes and the
long-running aqueousctl watch adapter while preserving existing DMS models/UI.
Update Go screenshot state queries to use the socket as well.

Settings and keybind editing use separate configuration helpers today. Their
migration is a second delivery requiring an Aqueous configuration service.
Complete runtime work first and report those remaining calls accurately.

Follow the DMS repository's AGENTS.md and existing app conventions. Keep changes
specific to the Aqueous provider, use existing QML wrappers and localization,
and measure idle resource use. No new transport dependency should be necessary
for the runtime JSON/socket client unless bounded framing requires native support.

## Current call sites and ownership

| DMS source | Current behavior | Planned change |
| --- | --- | --- |
| `quickshell/Services/AqueousService.qml` | Capability subprocess, persistent aqueousctl watch, runJson per action | Direct hello/query/command connection and subscription connection |
| `quickshell/Common/DankSocket.qml` and `dank-qml-common/DankCommon/Common/DankSocket.qml` | Shared socket wrapper and reconnect lifecycle | Reuse after auditing framing/size bounds and actual link state |
| `quickshell/Services/CompositorService.qml` | Consumes Aqueous window/workspace facade | Preserve public API and behavior |
| `quickshell/Services/SessionService.qml` | Delegates Aqueous logout | Preserve accepted-exit result handling |
| `core/internal/screenshot/aqueous_snapshot.go` | Runs aqueousctl for a fresh snapshot | Go Unix-socket snapshot client |
| `quickshell/Services/AqueousConfigService.qml` | Runs aqueous-config for snapshot/version/validate/apply | Follow-on configuration transport |
| `quickshell/Services/KeybindsService.qml`, `Common/AqueousKeybinds.js` | Runs dms keybinds commands and constructs argv | Follow-on DMS core RPC calls |
| `core/internal/keybinds/providers/aqueous_config.go` | Runs aqueous-config inside Go provider | Follow-on configuration socket client |
| `core/internal/keybinds/providers/aqueous.go` | Existing keybind inventory/edit mapping | Reuse mapping in resident core, preserve CLI |

The Aqueous repository also ships a DMS settings plugin under `dms-plugin/`.
Its ConfigClient and live layout calls belong to the Aqueous workstream. DMS
runtime migration alone does not migrate that plugin.

## Shared runtime contract: Aqueous IPC v1

This interface is implemented in the Aqueous source tree. DMS must still discover
capabilities because installed compositor binaries may predate it. The same
contract is included in both implementation plans.

### Discovery and transport

- Aqueous exports an absolute `AQUEOUS_SOCKET` path before starting session
  children. Path: `$XDG_RUNTIME_DIR/aqueous/<instance>/ipc.sock`,
  with a private, randomly named instance directory.
- Require a valid private runtime directory; do not fall back to shared
  `/tmp`. Directory mode is 0700, socket mode is 0600. Verify peer UID,
  rejecting both mismatches and credential-query failures.
- The socket is an AF_UNIX stream. Frames are one UTF-8 JSON object followed
  by LF. Embedded newlines must be JSON escapes. Reads/writes may split
  anywhere, including within a UTF-8 codepoint or across several frames.
- Use two persistent connections to the same endpoint in DMS: one for
  capabilities/queries/commands, one for capabilities/subscription/acks.
  This keeps a slow event stream from blocking command responses.
- Each connection performs `hello` before other operations. Each runtime
  request after hello carries the returned session token.
- Never guess a socket by scanning other sessions or invoking a discovery
  subprocess. Missing environment means unavailable on the socket backend.
  An inherited path is fixed for that DMS process; a new compositor instance
  requires a relaunched DMS with the new environment.
- Same-user access defines a trusted local desktop interface. It does not
  reproduce Wayland security-context filtering. Do not expose/mount the socket
  into untrusted application sandboxes; session tokens detect stale identity,
  they are not authentication secrets.

### Envelopes and handshake

Request IDs are nonempty decimal strings, at most 20 digits, strictly increasing
numerically within each connection. This enforces lifetime uniqueness without
retaining an unbounded ID history. Session tokens are 32 lowercase hex characters.
All entity IDs, sequences and delivery IDs remain strings.

Request:

```json
{"ipc":1,"id":"1","op":"hello","params":{}}
```

Successful response shape (the hello result below shows the required fields):

```json
{"ipc":1,"id":"1","ok":true,"result":{"session":"6b94a179d09456846b94a179d0945684","schema":1,"max_request_bytes":65536,"max_frame_bytes":4259840,"max_batch_bytes":4194304,"max_pending_requests":1,"capabilities":{"state":true,"commands":true,"keyboard":true,"overview":true,"shortcut_inhibition":true}}}
```

Error response:

```json
{"ipc":1,"id":"2","ok":false,"error":{"code":"locked","message":"Session is locked"}}
```

Bounds count encoded JSON bytes excluding LF. Client requests are at most
64 KiB. Server frames are at most 4 MiB + 64 KiB, allowing an envelope around
an existing batch of at most 4 MiB. Keep existing entity-state accounting
limits (currently 2 MiB) and admit at most 16 shell clients across transports.
Advertise these limits; clients must also enforce local hard limits.

An unsupported IPC or state schema version fails explicitly. Unknown optional
response fields may be ignored; unknown operations/actions and invalid command
parameters are rejected. Validate nesting depth, types, string sizes and
numeric ranges before allocating or dispatching. Malformed framing, invalid
UTF-8, reused or non-increasing IDs, invalid acks or oversized input close the
connection; emit a bounded error first only when safely possible.

### Operations

| Operation | Parameters | Successful result |
| --- | --- | --- |
| `hello` | Empty object; first request only | Handshake above |
| `snapshot` | Empty object | `{"batch": <complete shell snapshot>}` |
| `subscribe` | Empty object; once per event connection | `{"subscribed":true}`, then initial snapshot event |
| `ack` | `{"delivery":"N"}` | `{"acked":"N"}` |
| `command` | `{"action":"NAME","fields":{...}}` | `{"status":"applied","sequence":"N"}` or `accepted` |

All post-hello requests additionally contain top-level `"session":"TOKEN"`.
Validate it again when a queued mutation executes. A mismatch returns
`stale_session` without applying anything.

A subscribed connection accepts only ack after subscribe. Use the separate
request connection for snapshot and command. Allow one outstanding request per
connection in v1. DMS queues rapid commands
locally with a finite bound (proposed 32); excess requests report busy.
A server receiving another request before the previous reply returns `busy`
when possible without exceeding its output budget. Unsolicited events do not
count as outstanding requests. Each ack receives a response before any next
batch is enqueued, so the event client can clear its pending ack first.

### State and subscriptions

Event envelope:

```json
{"ipc":1,"event":"state","delivery":"1","batch":{"schema":1,"session":"6b94a179d09456846b94a179d0945684","sequence":"12","base_sequence":null,"type":"snapshot","upsert":[],"removed":[]}}
```

The empty entity list above illustrates framing only. Real snapshots contain
all current entities. Reuse the existing shell schema and DMS entity validator:
output, workspace, window, seat, keyboard, keyboard_device and session.
Preserve geometry, focus, visibility, capability and lock fields. Window IDs
remain foreign-toplevel identifiers; other entity IDs remain runtime identities.
Geometry is committed global logical geometry, not per-frame animation geometry.

A snapshot has `base_sequence:null`. A delta names the previous accepted
sequence in `base_sequence`, carries full replacement entities in `upsert`,
and removes keys in `kind:id` form through `removed`. Missing optional entity
values cannot retain stale previous values. Apply the complete batch atomically.
Sequence values may jump; compare as strings for equality and use BigInt or
checked integer parsing if ordering is needed, never JavaScript Number.

Only one unacknowledged batch may exist per event connection. Acknowledge its
exact delivery ID after successfully validating and installing it. Coalesce
changes while waiting; construct the next delta against the acknowledged
baseline. Never drop a delta and continue using its old baseline.
`snapshot` responses do not require an ack and do not create subscriptions.
The subscribe response must precede its initial snapshot event.

Publish only after policy, workspace and render transactions settle, using
existing dirty notifications. There is no polling or idle heartbeat.
Bound receive buffers, retained baselines, pending output and processing work
per event-loop turn. Partial writes resume on writability; disable writable
interest when the queue is empty.

### Commands and completion

Use the existing DMS action vocabulary:

| Action | Fields |
| --- | --- |
| `window.activate` | `id`, optional `seat` |
| `window.close` | `id` |
| `window.minimized`, `window.maximized`, `window.fullscreen` | `id`, boolean `value` |
| `window.move` | `id`, exactly one of `workspace` or `output` |
| `workspace.activate` | `id`, optional `seat` |
| `workspace.rename` | `id`, UTF-8 `name` up to 1024 bytes, no CR/LF |
| `keyboard.set` | optional `seat` and `group`, zero-based integer `index` |
| `keyboard.next` | optional `seat` and `group` |
| `overview.show`, `overview.toggle` | `output` |
| `overview.hide`, `session.exit` | Empty object |

Here `output` is a runtime output ID, `workspace` a runtime workspace ID,
`group` a keyboard group ID, and `seat` a seat name. Resolve runtime IDs
inside the shared backend rather than converting IDs to connector names in DMS.
Omitting seat requires exactly one seat; omitted group uses its active group.

Resolve targets when executing at a settled transaction. Recheck session lock,
policy mode and per-object eligibility there. Command errors include `invalid`,
`not_found`, `locked`, `unsupported`, `busy`, `ambiguous_seat`,
`unavailable`, and `stale_session`; operational/resource failures must also
produce explicit failures, never false success.

`applied` means the resulting operation has committed. Its sequence is the
committed state sequence; it may arrive before DMS receives the matching event
on the other connection. Do not optimistically rewrite authoritative state.
`accepted` is reserved for close and exit: close is a client request, not proof
of destruction. Flush exit acknowledgement before orderly shutdown, with a
bounded drain deadline so an unread socket cannot prevent logout.

### Recovery and compatibility

Use 5-second handshake/query/runtime-command deadlines and an 8-second initial
subscription deadline. Established idle subscriptions have no idle timeout.
Reconnect with bounded exponential backoff and jitter, using one reconnect
owner per connection. Fail pending commands on disconnect; a command sent
without a reply has an unknown outcome and must not be replayed automatically.
Discard queued old-session mutations and stale callbacks.

Both DMS connections must agree on session token before the backend is ready.
A broken stream invalidates the state model until a fresh subscription snapshot
is installed. Never merge across sessions or continue a broken delta sequence.
Keep the existing Wayland shell protocol and `aqueousctl` behavior compatible.
The new DMS backend does not silently fall back to process calls.

## DMS implementation sequence

### D1. Add fixtures and a small runtime socket adapter

- Implement an Aqueous-specific adapter, either inside AqueousService or a
  focused reusable helper. Keep JSON framing, lifecycle, correlation and errors
  separate from entity reduction and UI actions.
- Use two DankSocket instances at `Quickshell.env("AQUEOUS_SOCKET")`.
  Gate connection attempts on the Aqueous compositor selection and a valid path.
- Treat `linkUp` as the established connection state. The wrapper's
  `connected` property expresses connection intent and is not proof of a live
  connection. Send hello only after the underlying socket is ready.
- Audit current DankSocket.send behavior: it appends LF and does not prove
  delivery to the compositor. Detect oversized outbound frames before send.
- Check whether the configured parser bounds accumulated bytes before LF.
  A size check only inside SplitParser.onRead is too late for a peer that never
  sends LF. Use a bounded incremental parser; if the current QML API cannot
  provide that, add minimal native parser support through the shared component
  workstream and treat it as a release dependency.
- Reuse the wrapper's reconnect mechanism; remove the old process retry loop
  instead of running two retry owners. One-shot request deadlines are allowed;
  do not add repeating snapshot/heartbeat timers.
- Validate all envelopes, response IDs, result/error shapes, version fields and
  byte bounds. Keep runtime session identity distinct from connection generation.

### D2. Replace discovery and watch processes

- Replace `startWatching()`'s capabilities subprocess with hello on both
  connections. Validate equivalent session/schema/capabilities.
- Send subscribe after the event handshake. Process its response before the
  initial state event; mark available only after a valid full snapshot and both
  connections are ready.
- Retain validateEntity, reduceBatch and existing state facade semantics.
  Refactor acceptLine into an envelope parser plus acceptBatch, so a socket
  event's inner batch enters the existing reducer.
- Send ack only after the complete batch has been validated and installed.
  Track outstanding ack responses without treating them as state events.
- Preserve taskbar filtering, focus/seat selection, workspaces by output,
  keyboard groups, geometry and overview properties used throughout the UI.
- Disconnect/backend-change handling must invalidate authoritative state, reject
  queued commands and guard late callbacks by a local lifecycle generation.
- A state sequence mismatch, unexpected event or malformed batch triggers a
  clean reconnect/fresh snapshot, not a partial model repair.
- With no AQUEOUS_SOCKET or unsupported IPC, expose a clear unavailable reason.
  Do not silently restart the old helper transport. If legacy support becomes
  a release requirement, make it an explicit separately tested backend.

### D3. Replace per-action command processes

- Replace commandArguments with commandPayload using the action/field table.
  Preserve client-side UX validation, stale-facade session checks and existing
  callbacks; the server remains authoritative.
- Send runtime output IDs directly. Existing code converts those IDs to connector
  names for CLI arguments; remove that conversion for the socket.
- Keep one wire request outstanding on the command connection. Queue at most
  32 user commands in order; do not silently drop rapid workspace/click actions
  or coalesce actions unless their semantics explicitly permit it.
- Revalidate queued requests before sending and discard commands made against
  stale sessions or unavailable models. Handle busy/locked/not_found distinctly.
- Complete callbacks using the correlated response. Preserve applied vs accepted
  semantics and error toasts; do not infer successful mutation from socket.write.
- Do not wait for an event sequence to exactly equal the command result: events
  may coalesce and arrive on another connection. The committed response confirms
  the command, while normal events update the UI.
- On timeout/disconnect after sending, report uncertain outcome and refresh
  state. Never replay mutations automatically. Not-yet-sent queued actions can
  be failed definitively without implying that they executed.
- Preserve orderly logout: acknowledgement is authoritative, while EOF before
  acknowledgement is an uncertain result. Avoid an automatic logout retry.
- Remove watchComponent, command Process objects and process timeout machinery
  only after their runtime consumers have migrated. runJson remains temporarily
  for settings/keybind consumers until the follow-on phase.

### D4. Migrate Go screenshot state lookup

- Add a small `core/internal/aqueousipc/` client using Go's Unix socket support,
  context deadlines, bounded buffered framing and the same envelope validation.
- Dial AQUEOUS_SOCKET, hello, request snapshot with that session, and close.
  This occasional direct connection does not launch an aqueousctl subprocess.
- Decode sequence/ID values as strings and preserve exact numeric handling where
  existing geometry code requires it. Handle oversized frames without relying
  on an unmodified scanner's small default token limit.
- Feed the inner snapshot batch into parseAqueousSnapshot and preserve focused
  seat checks, outer geometry, output clipping, transforms and existing composed
  capture behavior. The socket changes state lookup, not pixel capture.
- Keep Go and QML protocol fixtures aligned. CLI screenshot operations may
  themselves be processes; the acceptance criterion is no additional aqueousctl
  process for compositor state.

### D5. Verify lifecycle, resources and user behavior

Extend existing:
`quickshell/tests/aqueous-service.test.mjs`,
`scripts/test-aqueous-service.py`,
`scripts/test-aqueous-integration.py`, and Go screenshot tests.

- Mock-socket tests: handshake, fragmented/coalesced UTF-8 frames, response/event
  demultiplexing, ack order, size bounds before newline, malformed errors,
  unsupported schema, missing socket and mismatched sessions between connections.
- State tests: full snapshot and replacement deltas, removed objects, session
  changes, keyboard hotplug, lock changes, multi-seat ambiguity, output migration
  and closed-window facades.
- Command tests: ordered rapid commands, queue limit, per-request callbacks,
  busy/locked errors, timeout before vs after send, response before state event,
  skipped/coalesced sequences, no automatic mutation replay and accepted logout.
- Reconnect tests: compositor unavailable at DMS start, connection failure,
  mid-batch disconnect, DMS restart, same-endpoint reconnect, and new compositor
  instance with DMS relaunched under new environment. Reject stale callbacks.
- Go tests: bounded fake Unix server, malformed/truncated/oversized frames,
  deadline cancellation, stale session and valid snapshot parsing.
- Real integration: private test compositor plus DMS; exercise dock activation,
  close/state/move, workspace switching/rename, keyboard selection, overview,
  screenshot targeting and session exit.
- Intercept/count aqueousctl launches in the actual runtime paths; verify zero
  during startup/discovery, sustained interaction, state watching and screenshot
  state lookup. Removing an executable string from source is not sufficient.
- Record idle process count, CPU/wakeups, bytes received, retained memory and
  reconnect behavior. Once connected and idle, no transport polling timers or
  child processes should run.
- Validate without the user's active Wayland/DMS sockets. Update docs/aqueous.md
  and integration test instructions with the exact binary/environment setup.

## Follow-on: settings and keybinds without per-operation helper launches

Prerequisite from Aqueous: a separately supervised `aqueous-config serve`
companion, advertised by `AQUEOUS_CONFIG_SOCKET`, plus a frozen configuration
transport spec and fixtures. Runtime IPC v1 does not yet define those messages;
do not infer them from the runtime command envelope.

The planned configuration service wraps existing protocol-1 helper objects for
version/snapshot/raw/validate/apply, retaining 4 MiB requests, explicit shell=dms,
capabilities, expected_generation, backups, atomic per-file replacement,
multi-file partial results and adapter reports. Its slow work stays outside the
compositor event loop. Configuration writes must serialize with retained helper
CLI clients and across sessions.

DMS work after that contract is published:

1. Add a persistent configuration client with bounded I/O, operation-specific
   deadlines, capability checks, reconnect and uncertain-save handling.
   AqueousConfigService sends requests directly; preserve draft snapshots,
   generation checking and validation/apply UX. Re-read saved state before
   retrying an uncertain Apply.
2. Put keybind inventory/edit/reset operations behind existing DMS core socket
   RPC mechanisms. Reuse aqueous.go mapping and conflict logic; replace its
   helperResult subprocess path with a direct configuration socket client.
   Quickshell calls resident core through DMSService, removing nested
   `dms keybinds ...` process launches.
3. Keep `dms keybinds` CLI commands working through the shared Go implementation.
   Replace argumentsFor with structured requests in the Quickshell path without
   duplicating serialization or bypassing retained-generation checks.
4. Preserve stale-draft reconciliation, external edits, missing capabilities,
   partial toolkit synchronization and the single enabled appearance-sync owner.
   Do not write Aqueous TOML from QML or introduce another config serializer.
5. Audit all consumers of AqueousService.runJson before removing that utility.
   Include cheatsheet and greeter paths, appearance settings, and provider changes
   so the Aqueous path stops launching helpers without changing other compositors.
6. Coordinate with Aqueous's separately shipped DMS plugin. Its live layout and
   configuration transport migration is owned in Aqueous, not fixed by modifying
   DMS's native provider.
7. Extend keybind/config tests with a real/fake configuration socket server,
   competing frontend saves, changed generation while queued, companion restart,
   uncertain apply, adapter partial failure and helper-launch counters.

The companion itself is one long-lived process. Toolkit utilities used during
explicit settings changes may remain and must be documented; do not claim the
entire desktop creates zero subprocesses.

## Delivery and acceptance

Deliver in reviewable increments:

1. Runtime protocol fixtures and socket adapter.
2. AqueousService discovery/events/commands migration.
3. Go screenshot snapshot migration.
4. Joint runtime integration, resource measurements and documentation.
5. Configuration/keybind migration after its separate server contract is ready.

Runtime delivery is complete when DMS uses the direct socket for all supported
runtime interactions and screenshots' state lookup, creates no aqueousctl
children for those paths, preserves the UI/state contracts, and passes isolated
reconnect/lock/flow-control tests. Settings/helper calls are explicitly outside
that first completion claim.

Full follow-on completion additionally requires no per-operation aqueous-config
or nested dms keybinds launches from migrated DMS providers, preserved config
conflict/partial-success behavior, and separately verified Aqueous plugin
migration. Retain CLI tools for user-invoked commands.

