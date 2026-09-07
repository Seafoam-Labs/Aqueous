# Aqueous: persistent IPC for DMS

Status: Aqueous runtime implementation delivered, 2026-09-06. DMS consumer
migration and the configuration companion remain separate workstreams. See
`../compositor/protocol/aqueous-ipc-v1.md` for the implemented protocol and checks.

## Outcome and scope

DMS connects directly to Aqueous for runtime state and commands. Routine window,
workspace, keyboard and overview interactions create no helper processes; state
arrives through an event-driven subscription. The compositor remains in control
of policy and transaction ordering.

Required first delivery covers the runtime socket, DMS screenshot-state query
support, session environment propagation, compatibility and integration tests.
Persistent settings/keybind transport is a separately scoped follow-on below;
do not describe runtime delivery as removing all settings helper calls.

The separately copyable DMS plan is
[`dms-ipc-socket-plan.md`](dms-ipc-socket-plan.md). It embeds the same proposed
wire contract and requires no files copied from Aqueous to understand the work.

## Existing implementation to reuse

| Area | Current source | Implication |
| --- | --- | --- |
| State, typed commands, subscriptions | `compositor/aqueous/ShellManager.zig` | Already owns session IDs, snapshots/deltas, settled dispatch and flow control; currently tied to Wayland resources |
| Existing shell API | `compositor/protocol/aqueous-shell-v1.{xml,md,schema.json}` | Preserve schema and behavior |
| Wayland CLI adapter | `compositor/aqueousctl/Shell.zig`, `main.zig` | Keep supported; not the transport used by new DMS |
| Unix output socket | `compositor/aqueous/wm/output/Service.zig` | Reference for event-loop integration, not a general shell backend |
| Server/session lifecycle | `compositor/aqueous/Server.zig`, `main.zig` | Own listener setup, teardown and exported endpoint |
| Session launch | `packaging/aqueous-init`, `packaging/aqueous-wm.sh`, `launch_river.sh` | Propagate endpoint to direct and service-launched DMS |
| Persistent settings helper | `plugin/helper/src/{main,config_document,schema,cursor_sync,toolkit_sync}.zig` | Owns configuration semantics and contains additional subprocess calls |
| Aqueous-shipped DMS plugin | `dms-plugin/services/ConfigClient.qml`, `pages/OverviewPage.qml` | Separate consumer; helper calls and layout queries need explicit coverage |

Do not copy the output socket unchanged: it currently uses a fixed path,
unlinks before binding, falls back to /tmp, and its credential predicate accepts
a failed getsockopt call. The new listener must have independent safe lifecycle
and fail-closed peer verification. Existing outputd compatibility is preserved.

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

## Implementation sequence

### A1. Freeze protocol and fixtures

- Add `compositor/protocol/aqueous-ipc-v1.md` and a JSON schema for transport
  envelopes, requests, actions, results and limits. Reference the existing shell
  entity schema rather than inventing a second state model.
- Turn the proposed examples into valid full fixtures: hello, populated snapshot,
  delta, ack, committed command, accepted close, stale session and errors.
- Specify per-connection and aggregate memory/work budgets in code. Initial
  targets: one pending batch plus bounded response output per client, 16 clients
  total, bounded callback reads/accepts/commands to avoid starving rendering.
- Keep the standalone DMS handoff contract synchronized if implementation changes
  any field, bound or sequencing rule.

### A2. Extract shared shell backend

Proposed modules: `ShellState.zig` / `ShellCommands.zig` or an equivalent
small shared service. Choose naming to match existing conventions.

- Move committed entity construction, runtime identity lookup, capability data,
  session/sequence ownership and typed command execution out of Wayland callbacks.
- Represent commands with backend-owned types; translate Wayland enums and JSON
  action names at their transport boundaries. No arbitrary action dispatcher or
  shell command execution endpoint.
- Introduce transport-neutral command completion and subscriber hooks. Preserve
  queued command lifetime, object disappearance checks, lock rechecks, pending
  close/exit behavior and publication after transactions settle.
- Update dirty/publication scheduling to count both socket and Wayland consumers.
  Today `dirty()` returns early when there are no Wayland clients; a socket-only
  DMS must still receive all publications.
- Keep one state build per dirty publication, not one full rebuild per client.
  Maintain per-subscriber acknowledged baselines and bounded lifetimes.
- Run existing shell regression coverage before introducing the socket so this
  extraction can be reviewed independently.

### A3. Add compositor-owned socket transport

Proposed module: `compositor/aqueous/IpcServer.zig`.

- Create the private instance directory and listener, retain ownership metadata,
  and register a nonblocking FD with the Wayland event loop. Use CLOEXEC for
  listener and accepted sockets.
- Start listening and export the endpoint before `server.aqueous.start()` or
  startup-command execution can launch consumers.
- Incrementally parse bounded frames; retain incomplete UTF-8 bytes until a
  complete frame exists. Reject malformed frames before dispatch.
- Maintain partial-write offsets and writable event interest. Keep all compositor
  state access on the compositor thread, with bounded work on each callback.
- Implement hello, snapshot, subscribe, ack and typed command handling according
  to the shared contract. Keep observer access possible in diagnostic external
  policy modes while rejecting mutations, as the existing API does.
- Cancel queued work belonging to destroyed connections and release event sources,
  buffers and baselines. A disconnected client must not leave dangling callbacks.
- On shutdown unlink only this instance's owned socket and remove its directory.
  Never steal or remove a live endpoint belonging to another compositor.
- If optional IPC initialization fails, log a clear diagnostic, export no endpoint,
  clear any inherited AQUEOUS_SOCKET, and let the compositor run; DMS reports the
  integration unavailable. No false capability advertisement.

### A4. Export the actual session environment

- Set `AQUEOUS_SOCKET` in the live process environment for native startup and
  keybinding children.
- Fix `main.zig`'s explicit startup-command environment construction too: it
  copies the initial environment rather than simply using later setenv values.
  Filter inherited AQUEOUS_SOCKET and append the newly selected assignment.
- Add the variable to the UWSM finalize, D-Bus activation and systemd import paths
  in `packaging/aqueous-init`; update its packaging tests.
- Keep nested launcher environments private. Do not export a nested compositor's
  endpoint into the real user's global service environment.
- Make the session/service owner stop/relaunch DMS with fresh environment on a
  compositor restart. Reconnection to an old per-instance path cannot discover
  a new instance by itself.
- Audit source/binary/Nix session packaging so installation variants use the same
  export contract. Avoid assuming an environment imported into a service manager
  changes already-running processes.

### A5. Runtime consumers and compatibility

- Preserve Wayland XML, schema, CLI commands and their exit/result behavior.
  Converting aqueousctl into a socket client is not required for DMS migration.
- Support fresh socket snapshots for the DMS Go screenshot client. Standard
  Wayland capture remains responsible for pixels.
- Leave `outputd.sock`'s existing contract intact; do not reinterpret its
  output operations as shell actions.
- Audit the shipped plugin's live layout query/set calls separately. They are
  outside the current shell action set. Before migrating them, add capability-
  gated `layout.query` / `layout.set` with runtime output IDs, allowed layout
  names and existing committed-result semantics; publish their exact schema
  and DMS fixtures together. Do not claim this plugin is process-free in A1-A5.
- Update README, compositor README, shell API docs, architecture docs and DMS
  integration guides where they currently promise there is no separate socket.
  Clarify which documents are historical handoff snapshots.

### A6. Validation and release gates

Use isolated runtime/config directories and private headless or nested displays.
Never connect tests to the user's active desktop.

- Codec tests: fragmented and coalesced frames, split UTF-8, invalid JSON/types,
  oversized/no-newline input, unknown versions, ID reuse, stale session, nesting
  limits and bounded output.
- Real socket tests: disconnect mid-frame/mid-response, failed credential query,
  refused foreign UID when feasible, full client table, blocked reader, partial
  writes, reconnect, shutdown cleanup and two simultaneous compositor instances.
- State/action tests: socket-only subscriber receives changes; initial snapshot
  then valid deltas; ack pause/coalescing; disappearing targets; lock acquired
  after queueing; multi-seat ambiguity; command completion after commit;
  response/event arrival in either cross-connection order; close and exit ack.
- Compatibility tests: socket and Wayland clients see equivalent committed state
  and effects for the same operations; existing `zig build test` and
  `compositor/scripts/test-shell-integration.py` continue to pass.
- Environment tests: startup command, native exec, service startup and nested
  sessions receive the correct instance path, including inherited stale values.
- Joint DMS test: real DMS socket backend, launch counters for aqueousctl, rapid
  interactions, DMS restart, compositor restart with DMS relaunch, idle traffic,
  memory bounds and frame responsiveness with a deliberately slow consumer.
- Measure before/after process creation, idle CPU and interaction latency. Set
  performance assertions from a reproducible baseline; do not invent speedup
  percentages or brittle universal timing thresholds.

Runtime acceptance: zero aqueousctl invocations for discovery, watch, supported
runtime commands and screenshot state lookup; no polling/heartbeat; bounded
resource use; all existing shell protocol behavior preserved.

## Follow-on: persistent configuration and remaining helper calls

This is a second delivery, not a hidden requirement for opening the runtime
socket. It is needed if the desired endpoint is also zero per-operation helper
launches for settings and keybind editing.

1. Extract the existing helper's operation layer from argv/stdin/stdout plumbing.
   Preserve version/snapshot/raw/validate/apply results, schema-backed fields,
   generation checks, backups, atomic per-file replacement, multi-file partial
   failure and toolkit adapter reports. Do not put file I/O, font enumeration or
   toolkit work in the compositor event loop.
2. Add a persistent `aqueous-config serve` companion using a separate private
   `AQUEOUS_CONFIG_SOCKET`. It runs once per applicable session, supervised by
   session packaging, and shares the helper operation implementation. This adds
   one long-lived configuration process, not a helper invocation for each click.
   The compositor owns only the runtime socket.
3. Before implementation, freeze a separate configuration transport spec and
   fixtures. Carry existing protocol-1 helper request/result objects in correlated
   envelopes for version/snapshot/raw/validate/apply; preserve the 4 MiB request
   bound, explicit shell=dms, expected_generation and operation deadlines.
   Runtime v1's 64 KiB request limit must not be reused for configuration drafts.
4. Serialize writes across the companion and retained CLI/helper clients using a
   shared cross-process lock. Re-read/check generation while holding that lock;
   serialize callbacks and distinguish saved configuration from applied runtime
   state. Multiple sessions editing the same config must not bypass conflict
   detection. Lock policy must be checked at mutation execution through a trusted
   live-session mechanism and fail closed when session state cannot be verified.
5. Audit helper subprocesses too. `main.zig` queries outputs with aqueousctl;
   `cursor_sync.zig` queries/sets compositor cursor state with aqueousctl.
   Add capability-gated runtime output/cursor query/update operations or direct
   protocol clients, and migrate those internal calls. Freeze extension schemas,
   output-mode parity and cursor result semantics before DMS depends on them.
   Document any remaining toolkit/system commands: eliminating DMS transport
   processes does not mean eliminating every external utility.
6. Migrate Aqueous-owned `dms-plugin/services/ConfigClient.qml`, startup checks,
   compatibility messaging and live layout calls when their replacement APIs are
   available. Preserve draft retention and the single enabled appearance-sync
   owner. Keep Noctalia compatibility paths working.
7. Add service packaging, helper CLI parity tests, concurrent-edit tests, uncertain
   save recovery, companion crash/restart and process counters. Publish the
   configuration transport extension in the standalone DMS handoff before the
   second DMS phase begins.

## Reviewable delivery order

- Protocol/schema/fixtures and shared backend extraction.
- Runtime listener, lifecycle and environment propagation.
- Isolated protocol/regression tests and socket-aware documentation.
- Joint DMS runtime migration and measured acceptance evidence.
- Separately reviewed configuration companion and remaining consumer migration.

The runtime server, shared command backend, session exports, schema, fixtures
and isolated socket/Wayland regressions are implemented. Joint DMS process-count
and UI acceptance requires the DMS handoff implementation; the configuration
companion remains the separately scoped follow-on above.


## Implementation validation (2026-09-06)

- Default Vulkan and diagnostic ReleaseSafe builds succeeded using the pinned
  wlroots render hook and a writable temporary Zig cache.
- Default and diagnostic `zig build test` succeeded, including the IPC codec.
- The complete shell integration regression passed through both the retained
  Wayland adapter and the new IPC command/snapshot adapter.
- Socket-only integration passed: state/ack coalescing, fragmented UTF-8,
  malformed/oversized input, monotonic IDs, stale sessions, 5,000 pipelined
  backpressure requests, client admission, multiple instances, cleanup,
  native/startup endpoint exports and failed setup without stale inheritance.
- External and comparison policy sessions allowed socket snapshots and rejected
  mutations; mocked UWSM/D-Bus/systemd exports and nested isolation passed.
- Twelve captured frames validated against the transport and existing shell
  JSON schemas. Both standalone handoff contracts remain synchronized.

These checks used private headless sessions. They do not establish physical GPU
latency improvements or certify a DMS consumer that has not yet been migrated.
