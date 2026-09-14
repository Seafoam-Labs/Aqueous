# Physical display preview implementation and acceptance

Workstream 5 implements the runtime checks and an isolated SDR qualification
path. **Physical acceptance is still incomplete; production physical previews
remain disabled.** No hardware acceptance record was produced by this change.

## Runtime contract

The compositor advertises `display_preview_completion_v1`. A preview tests the
whole target output set before scheduling it and retains at least one enabled,
non-mirrored output. It enters `previewing` only after every participating
output's state matches and each enabled output has presented a newer frame.
Sequence comparison handles wraparound and ignores old presentations. Only then
does the 15-second confirmation interval start. Disabling an output requires
observed disablement rather than a presentation from that disabled output.

Actual mode dimensions/refresh, scale, transform, enablement, HDR/color state and
adaptive sync are checked against wlroots. Logical placement, mirror routing and
the complete scheduled/current state are checked against the compositor's
transaction. Keep rechecks both views, output identity, session activity and lock
state before authorizing persistence.

`affected_outputs` adds `hardware_matches` and `presented`. Restoration is not
reported merely because an in-memory state struct equals its baseline. Failed
group commits restore scheduled state after ordinary failure cleanup, including
a backend that applied one member before failing. Baseline test failure still
uses the existing tested usable-output fallback; partial restoration and fallback
remain explicit in the lease result.

An inactive session transitions to `waiting_session`. It cannot confirm or admit
a competing preview. Restoration resumes when the session becomes active; its
rollback deadline starts then. Session lock and presentation failures invalidate
the preview. Connector removal continues to use session-scoped output identities,
preserving newer state and reporting removed outputs.

The commit deadline cannot race a helper that still holds the writer lock.
`waiting_for_commit_writer` retains `commit_authorized` until the compositor can
recover the journal and read the decision. A decision binds the operation ID,
preview token, original generation and candidate digest. Recovery errors report
`commit_recovery_failed` rather than claiming a successful rollback. A stopped
writer must eventually resume or exit; elapsed time alone cannot decide its
durable outcome.

The existing journal remains the persistence authority: an unconfirmed preview
writes no candidate files; prepared interrupted transactions restore original
files; committed transactions recover candidate files and durable receipts.
Restart invalidates old compositor-session tokens and loads the recovered
canonical generation. `store:true` never substitutes for protected apply.

## Backend and feature gates

Each observed output includes `preview_backend` and `preview_acceptance_only`.
The existing support fields now give backend/feature-specific reasons.

| Backend/group | Production | Isolated acceptance build |
| --- | --- | --- |
| Headless ordinary display operations | Available | Same software path |
| DRM ordinary SDR, advertised modes | Acceptance pending | Explicitly selected connectors only |
| DRM HDR, VRR, mirroring, custom modes | Acceptance pending | Still blocked |
| Nested/other backends | Unsupported | Unsupported |

An acceptance build rejects SDR tests with HDR/VRR active, Auto HDR enabled,
mirroring configured, or a custom mode. All participating DRM connectors must
be explicitly selected. Renderer-dependent headless mirroring retains its
existing renderer check.

`display_preview_hardware` stays false in every build. The separate
`display_preview_acceptance_build` flag identifies a test binary. There is no
caller-supplied acceptance assertion and no wildcard connector selector. Do not
ship or package this test build, or use it as Pearl's production dependency.

## Build and run the acceptance harness

Build the normal pinned wlroots dependency first. From `compositor/`:

```sh
zig build -Ddisplay-preview-acceptance=true -Doutput-retry-testing=true \
  --prefix /tmp/aqueous-preview-acceptance
```

Build the matching helper and its explicit `test-driver` target. The latter
provides helper-crash checkpoints and is never a production helper replacement.

The harness defaults to read-only inventory:

```sh
python3 scripts/test-display-preview-physical.py --artifacts /tmp/preview-inventory
```

Physical execution requires a dedicated seat/TTY and an independently usable
recovery console. End the ordinary graphical session on that seat first. The
following example changes real output state; replace the card and connector
names with those of the disposable test setup:

```sh
python3 scripts/test-display-preview-physical.py --run-sdr \
  --dedicated-seat --recovery-console \
  --drm-device /dev/dri/card1 --connector DP-1 --connector HDMI-A-1 \
  --compositor /tmp/aqueous-preview-acceptance/bin/aqueous \
  --helper /path/to/aqueous-config --driver /path/to/aqueous-backend-test \
  --wlroots-lib /path/to/patched/wlroots/lib --fault-injection \
  --artifacts /tmp/preview-physical-run-1
```

The runner creates private home/config/state/runtime directories and a private
D-Bus session. It uses negotiated structured declaration edits and protected Keep
with receipts. It never installs services or edits the ordinary user's display
configuration. It terminates only processes it started. Use a fresh artifact
directory for every run.

Artifacts record kernel, DRM device/driver paths, connector status/modes, EDID
bytes/hash, native monitor identity/model, selected renderer logs, source revision
and file hashes, binary/dependency hashes, helper version, actual output states,
rollback evidence and operation receipts. Cases are independently `passed`,
`failed` or `not_run`. The report always leaves `acceptance_complete:false` for
the separate hardware review; it never changes production gates.

Automatic cases cover placement, scale, transform, another advertised mode when
available, disabling one head in a multi-head setup, timeout, disconnect, Keep,
helper prepared/committed crashes and compositor restart at those boundaries.
`--fault-injection` adds preflight failure, commit failure and partial group
commit. A single-output setup cannot qualify multi-output cases; a monitor with
no alternative mode leaves the mode case unrun.

To validate the harness without physical acceptance:

```sh
python3 scripts/test-display-preview-physical.py --simulate --fault-injection \
  --compositor /tmp/aqueous-preview-acceptance/bin/aqueous \
  --helper /path/to/aqueous-config --driver /path/to/aqueous-backend-test \
  --wlroots-lib /path/to/patched/wlroots/lib
```

Simulation reports `group:headless-simulation` and `hardware_exercised:false`.

## Outstanding hardware acceptance

The harness leaves physical hotplug during preview/commit, lease loss,
suspend/resume, unusable-baseline fallback and rollback failure unrun. Perform
these under recovery-console supervision and retain native status, before/after
configuration digests, receipts, connector identities and evidence of a usable
restored output. Do not treat a tested fallback as exact restoration or an
injected backend error as proof of a real driver fault path. Repeat with the
actual intended GPU/driver/kernel, connector and monitor combination.

HDR, VRR, mirroring and custom modes need their own implementation/acceptance
groups before their gates can open. No production allowlist is added here.

Software validation on 2026-09-14 passes all 504 compositor unit tests, the
native headless protected transaction suite and three harness admission tests.
The harness simulation passes 15 automated cases and leaves seven cases unrun.
New native scenarios exercise delayed presentation,
failed and partial commits, simulated inactive-session recovery, tested fallback
and a writer stopped beyond the commit deadline. These are software evidence,
not physical hardware acceptance.
