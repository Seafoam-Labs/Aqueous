# Physical display preview implementation and acceptance

Production DRM previews support SDR, HDR, VRR, combined HDR+VRR, and Auto HDR,
subject to hardware capabilities and backend preflight. No acceptance build,
connector allowlist, environment selection, or hardware acceptance record is
required. The existing protected preview, presentation, confirmation, rollback,
and persistence checks apply to physical displays. Mirroring and custom modes
remain separately gated. Physical qualification coverage is documented below;
production enablement does not claim that those hardware checks have run.

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
| DRM ordinary SDR, advertised modes | Available after backend preflight | Explicitly selected connectors only |
| DRM HDR, VRR, HDR+VRR, Auto HDR | Available when hardware supports the feature and preflight passes | Explicitly selected features and connectors |
| DRM mirroring, custom modes | Acceptance pending | Still blocked |
| Nested/other backends | Unsupported | Unsupported |

The classifier includes baseline state, effective target, deferred declarations,
and profile members, including offline selectors. Ordinary layout edits preserve
all participating outputs' active features. `apply_on_reload=false`, profiles,
and raw TOML do not bypass feature admission. Hardware capability is checked per
output. An SDR companion need not support HDR. In acceptance builds, the selected
feature requirement is the union across the lease: HDR on one head plus VRR on
another requires selecting the combined group. Production does not require
feature selection.

In an acceptance build, all participating DRM connectors must be explicitly selected with
`AQUEOUS_DISPLAY_PREVIEW_ACCEPTANCE_OUTPUTS=DP-1,HDMI-A-1`. The additional
`AQUEOUS_DISPLAY_PREVIEW_ACCEPTANCE_FEATURES` variable defaults to `sdr` and
accepts comma-separated `sdr,hdr,vrr,hdr_vrr,auto_hdr`. `hdr_vrr` includes HDR and
VRR; `auto_hdr` includes HDR. Selecting `hdr,vrr` does **not** select their combined
group. Empty, unknown, wildcard, and trailing-comma feature names are rejected.
These variables only restrict acceptance builds; production admission ignores
them, including invalid or stale selections. Mirroring and custom modes retain
independent qualification gates.

`display_preview_hardware` and feature diagnostics
`production_hardware_enabled` are true in production builds and false in
acceptance builds. They describe the build policy, even in a headless session;
they do not promise support for every connected output or operation. Use the
per-output support results and candidate admission for that decision. The separate
`display_preview_acceptance_build` flag identifies a test binary. There is no
caller-supplied acceptance assertion and no wildcard connector selector. Do not
ship or package this test build, or use it as Pearl's production dependency.

## Build and run the acceptance harness

Build the normal pinned wlroots dependency first. From `compositor/`:

```sh
PKG_CONFIG_PATH="$PWD/.deps/wlroots-render-hook/lib/pkgconfig" \
  zig build -Dxwayland -Ddisplay-preview-acceptance=true -Doutput-retry-testing=true \
  --prefix /tmp/aqueous-preview-acceptance
```

Build the matching helper and its explicit `test-driver` target. The latter
provides helper-crash checkpoints and is never a production helper replacement.
From the repository root:

```sh
zig build --build-file settingsApplication/build.zig install test-driver \
  --prefix /tmp/aqueous-preview-helper
```

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
`failed`, `unsupported`, or `not_run`, with a summary by status. The report always leaves `acceptance_complete:false` for
the separate hardware review; it does not control production admission.

Automatic cases cover placement, scale, transform, another advertised mode when
available, disabling one head in a multi-head setup, timeout, disconnect, Keep,
helper prepared/committed crashes and compositor restart at those boundaries.
`--fault-injection` adds preflight/full/partial commit failure, delayed and
rejected presentation, simulated session loss, and baseline/fallback failure.
HDR/VRR commit faults exercise both transition directions. A single-output setup cannot qualify multi-output cases; a monitor with
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
suspend/resume, visual HDR accuracy, and measured panel VRR unrun. Injected
fallback and rollback tests do not qualify the corresponding real driver failures. Perform
these under recovery-console supervision and retain native status, before/after
configuration digests, receipts, connector identities and evidence of a usable
restored output. Do not treat a tested fallback as exact restoration or an
injected backend error as proof of a real driver fault path. Repeat with the
actual intended GPU/driver/kernel, connector and monitor combination.

Retain reviewed physical results separately for each HDR/VRR group. These results
document hardware coverage rather than unlock production previews. Mirroring and
custom modes remain separate future work. There is no production hardware allowlist.

## HDR and VRR runs

Use `--run-group hdr`, `vrr`, `hdr_vrr`, or `auto_hdr` in place of `--run-sdr` in
the physical command above, with a fresh artifact directory per run. The first
`--connector` is the feature test monitor; other connectors participate as
companions. The harness selects the matching environment feature group, keeps a
baseline through the protected helper, tests transitions and layout preservation,
and exercises rotated `[3880,-920]` placement on a second monitor. HDR runs also
test peak/SDR-white changes; combined runs test each feature independently;
Auto HDR runs test enablement and boost endpoints.

For example, after building the compositor and matching helper:

```sh
python3 scripts/test-display-preview-physical.py --run-group hdr_vrr \
  --dedicated-seat --recovery-console \
  --drm-device /dev/dri/card1 --connector DP-1 --connector HDMI-A-1 \
  --compositor /tmp/aqueous-preview-acceptance/bin/aqueous \
  --helper /tmp/aqueous-preview-helper/bin/aqueous-config \
  --driver /tmp/aqueous-preview-helper/bin/aqueous-backend-test \
  --wlroots-lib "$PWD/.deps/wlroots-render-hook/lib" --fault-injection \
  --visual-seconds 120 --artifacts /tmp/preview-hdr-vrr-run-1
```

Feature runs compile `fixtures/preview-reference-client.c` in their artifact
directory using `cc`, `pkg-config`, `wayland-scanner`, Wayland client development
files, and wayland-protocols. `--reference-client PATH` accepts a prebuilt copy;
`python3 scripts/build-preview-reference.py /tmp/preview-reference` builds one.
HDR/HDR+VRR use 10-bit PQ BT.2020 neutral patches at 0, 80, 203, 400, 1000, and
4000 cd/m². VRR and Auto HDR use an SDR highlight ramp. A moving bar cycles
requested cadence through 40, 60, 90, and 48 fps every four seconds. Fullscreen
placement uses the primary test output. Logs record submitted cadence, not actual
panel refresh. The scene is a reference workload, not calibrated measurement
instrumentation; clipping above the display peak is expected.

`--visual-seconds 120` leaves the group baseline and reference scene visible after
the automated cases. Record display OSD/driver refresh observations, perceived
flicker, HDR appearance, metadata measurements if available, and usable output
after rollback separately alongside `report.json`. `visual-hdr` and `panel-vrr`
remain `not_run` until reviewed manually; their applicability depends on the group.
The harness cannot self-certify them. Mode-specific VRR support still depends on
backend preflight; capability discovery alone does not prove every mode works.

## Negotiated feature diagnostics

`hello.capabilities.display_preview_feature_policy_v1` negotiates two read-only
native requests. Send the usual IPC session envelope:

- `display.preview.features`, with empty parameters, returns `version:1`, session,
  the production enablement flag, and per-output capability/selection plus feature
  support. Each feature has `preserve` and `transition` results with `status` and
  a nullable stable `reason`. Status is `available`, `acceptance_only`,
  `pending_qualification`, or `unsupported`. Hardware capability and qualification
  are separate; `layout` accounts for already-active features on all heads.
- `display.preview.evidence`, with `{"token":"<lease token>"}`, returns the
  baseline/target and current observed HDR, adaptive-sync status, render format,
  hardware/color matches, and submission/presentation progress. Auto HDR fields
  are explicitly compositor state. Removed outputs have `observed:null`.

The helper exposes these as `aqueous-config preview-features --shell none` and
`aqueous-config preview-features --shell none --token TOKEN`. The corresponding
response members are `preview_features` and `preview_evidence`. A legacy
compositor without the negotiated capability rejects this query. Existing
snapshot and lease result shapes remain unchanged. Consumers must negotiate
feature support rather than interpret the build-wide `display_preview_hardware`
flag as a per-feature result. Candidate admission is authoritative.

Rejection codes distinguish `hdr_unsupported`, `vrr_unsupported`,
`mode_not_advertised`, `acceptance_output_not_selected`,
`acceptance_features_invalid`, and `<feature>_acceptance_not_selected` in
acceptance builds. Production SDR/HDR/VRR/Auto HDR no longer return
`hardware_acceptance_pending` or their feature-specific pending reasons. Physical
mirroring and custom modes retain their `*_hardware_acceptance_pending` reasons.
Ordinary backend test/commit failures
remain separate. Evidence cannot prove cable metadata delivery or panel behavior.


## Software validation

Validation on 2026-09-16 passed 514 compositor unit tests, 61 helper unit tests,
seven harness policy/admission tests, the native headless preview/transaction
suite with old and new response schemas, structured display and protected
collection schema tests, and helper package staging. Production and acceptance
Vulkan builds and the diagnostic build compiled; packaging accepts the production
policy and rejects the acceptance policy. The reference client compiled with
warnings treated as errors. The final private headless harness run passed all 26
automated cases with the SDR reference client; five physical/mode cases remained
unrun. No simulated result counts as hardware qualification.
Physical HDR output, HDR reference rendering, actual variable panel refresh, and
real device/session fault qualification remain step 5.
