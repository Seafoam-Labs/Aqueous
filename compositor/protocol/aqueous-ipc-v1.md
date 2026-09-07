# Aqueous IPC v1

This interface is implemented in the Aqueous source tree. DMS must still discover
capabilities because installed compositor binaries may predate it. The version is independent of the retained Wayland protocol version.

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

## Implementation and resource budgets

`ShellManager.zig` owns state, session/sequence identity, subscriptions and settled
publication for both transports. `ShellCommands.zig` executes transport-neutral
`ShellCommand.zig` commands. `IpcServer.zig` owns only socket framing, I/O and
lifecycle; it never dispatches commands through aqueousctl or another process.

The instance name is the compositor's random session token. An existing owned
`aqueous` parent directory is tightened to 0700 for compatibility with older
outputd installations. The runtime directory must already be owned and 0700;
symlink directories are rejected. IPC setup failure is logged and clears the
inherited endpoint while allowing the compositor to continue.

There are at most 16 shared shell clients, including sockets that have not sent
hello. Each socket holds a 65537-byte input buffer, at most 4325376 queued output
bytes, and one state baseline with the existing 2 MiB state accounting bound.
Allocator capacity/hash overhead and one transient JSON serialization/parser
allocation add to those logical limits. Requests are limited to nesting depth 16.
Hello also advertises max_clients, max_state_bytes and max_depth.

Each callback accepts at most 8 sockets, reads at most 8 chunks of 8192 bytes,
processes at most 16 buffered frames per chunk/service pass and writes at most
256 KiB. Remaining buffered frames resume from an idle callback. There is no
recurring IPC timer. A one-second timer bounds draining an accepted exit reply.
Ack replies are queued before the next state event. Reading a complete response
is required before submitting another request; pipelining can return busy.

The socket is a trusted same-UID desktop interface, not a sandbox grant mechanism.
The Wayland shell global retains its separate security-context filtering.
Neither connection exposes arbitrary command execution or configuration writes.

## Validation

The schema is `aqueous-ipc-v1.schema.json`; captured protocol fixtures live in
`scripts/fixtures/ipc/`. JSON schemas describe structure; byte limits, sequence
continuity, strictly increasing request IDs and transaction timing also require
runtime checks. The existing shell schema defines the inner batch.

Build with the repository's pinned wlroots and a writable Zig cache. For isolated
Pixman tests, use a `-Dvulkan-effects=false` build and set binary overrides:

```sh
zig build test -Dvulkan-effects=false
AQUEOUS_COMPOSITOR_BIN=/path/to/aqueous python3 scripts/test-ipc-integration.py
AQUEOUS_COMPOSITOR_BIN=/path/to/aqueous AQUEOUSCTL_BIN=/path/to/aqueousctl \
  AQUEOUS_SHELL_TEST_IPC=1 python3 scripts/test-shell-integration.py
AQUEOUS_COMPOSITOR_BIN=/path/to/aqueous AQUEOUSCTL_BIN=/path/to/aqueousctl \
  python3 scripts/test-shell-integration.py
```

Run `bash packaging/tests/test-aqueous-init.sh` from the repository root to test
mocked UWSM, D-Bus and systemd endpoint propagation and nested-session isolation.
The integration fixtures launch private headless compositors and do not connect
to the user's desktop. Socket binding must be permitted in the test environment.

DMS migration is documented in `docs/dms-ipc-socket-plan.md` at the repository
root. Until that consumer work lands, DMS continues to use its existing process
adapter. Persistent settings/keybind configuration transport is a later phase.
