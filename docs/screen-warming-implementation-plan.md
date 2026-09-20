**Screen warming: implementation plan**

Status: software implementation is present locally, with private headless validation.
Physical qualification, non-neutral calibration support and production enablement
remain pending. See [the implemented contract](screen-warming.md) for exact wire
semantics, the initial support boundary and reproducible checks. The design below
retains the acceptance requirements for future production qualification.

Evidence baseline supplied by Pearl: Aqueous
`88587243059d58d72dd0fe2146d0ebdb64f26474`, wlroots 0.20.2 archive SHA-256
`972c7ac44b17828f4702bfae7cd8347346a3fb5b2c1076cfa2c3fcedac5ec343`, and patches
0025/0026. Planning also inspected current Aqueous
`7ac4af2f9990ea36192aefc41adf3845b1249015` and Pearl
`cb4cb780276e4058f8b32455d3e98edf83e9d042`. The build script retains that archive
pin. Current source provides output instance IDs, commit/presentation tracking,
and several scene/backend commit paths to integrate. No new physical tests were
performed while preparing this plan.

**Implementation choice**

Add an experimental `aqueous-output-warming-v1` Wayland protocol with observation,
exclusive leases, generation-checked requests and explicit commit results.
Keep scheduling, preferences and temperature selection in Pearl; let Aqueous
own transform construction, composition, eligibility and restoration. A native
request avoids making a new safety contract depend on unacknowledged legacy LUT
writes. Do not extend settings-helper snapshots into write authorization.

Start with a validated SDR renderer composition path. While warming is active,
disable direct scanout, overlay promotion and final-conversion offload unless
each can prove the identical transform and restoration semantics. Hardware
cursor color must also participate: force software cursors for this initial
path. Restore optimization locks only after the neutral state commits.
This intentionally narrows initial support; hardware LUT/offload support is a
separate expansion with its own acceptance gate.

**1. Specify the output and lease contract**

Primary additions: `compositor/protocol/aqueous-output-warming-v1.xml`, an
accompanying protocol contract document, and
`compositor/aqueous/OutputWarming.zig`. Integrate object lifetime through
`OutputManager.zig` and `Output.zig`; register/package the protocol through
`compositor/build.zig` and existing global visibility policy in `Server.zig`.

Bind observation to a live `wl_output` resource on the same Wayland connection.
Connector names are labels, never authorization keys. Reuse `display_instance`
only after verifying its lifetime guarantees, and pair it with a compositor
session identity. A reconnect/hotplug produces a new identity even if the
connector and EDID are unchanged.

Publish complete snapshots terminated by `done`, containing:

| Field | Meaning |
| --- | --- |
| Session and output instance | Identity of this live output; invalid after removal/reconnect |
| Color generation | Opaque, non-reused token for eligibility and color-path dependencies |
| State revision | Orders observation updates, including ownership/status updates |
| Eligibility and reason | `eligible`, `ineligible`, or `unknown`; unknown denies acquisition |
| Output encoding | Actual SDR/HDR/unknown encoding, distinct from configured intent |
| Calibration state | Baseline identity/revision and supported, absent-under-compositor-control, external, or unknown provenance |
| Path and validation | Backend/renderer/path identity, qualification revision and available status precision |
| Ownership | Free, warming-owned, legacy-owned or restoring; no client identity disclosure needed |
| Current application | Lease/request identity, last known committed value and pending/failed/restoring status |

Use fixed-width high/low words for wide wire tokens; specify lifetime, ordering,
wrap handling and unknown enum behavior. Never reuse a token after wrap: retire
the affected identity. Pearl must not confuse this generation with its settings
or UI snapshot generation.

Define these operations and events in XML before implementation:

| Operation | Required behavior |
| --- | --- |
| Observe output | Return one coherent snapshot and subsequent complete updates |
| Acquire(expected generation) | Check identity, current/pending eligibility and shared ownership atomically; return lease or structured denial |
| Set(lease, generation, request ID, temperature) | Validate range, lease and generation; queue bounded compositor work |
| Release(request ID) | Stop accepting writes and request baseline restoration; keep a result object alive for acknowledgment |
| Destroy/disconnect | Perform the same server-side cleanup even when no result can be delivered |
| Revoked(reason, generation) | Lease is terminal; queued requests cannot commit afterward |
| Request result | Correlate each request with committed, rejected, failed, superseded or revoked outcome |

Support Pearl's existing 2500–6500 K range with a specified algorithm version;
6500 K is exactly the no-warming transform. Describe temperature as a control
parameter, not a measured display white point. Bound pending work to one
in-flight commit and the newest queued target per output; explicitly complete
superseded requests. Define monotonic request IDs, duplicate handling, resource
limits and normal runtime denials separately from malformed protocol errors.

Acceptance: generated client/server bindings and protocol fixtures demonstrate
snapshot coherence, identities, version negotiation and all object lifetimes.
Advertisement alone never makes an output available.

**2. Centralize eligibility and enforce it at the commit boundary**

Implement one authoritative per-output color state machine, with immutable
baseline/transform references and separate desired, prepared and committed
state. Initial eligibility requires a live, powered, session-active SDR output,
a qualified renderer path, known compositor-owned baseline, and no conflicting
owner. HDR/unknown encoding, unknown calibration, unqualified paths, unavailable
devices and pending conflicting transitions deny acquisition/application.

Invalidate the color generation when mode, encoding/HDR metadata, calibration,
renderer/device, scanout/offload policy, mirroring, power, session or output
lifetime changes can alter that proof. Include format/precision changes and
scale/transform changes that alter the chosen path. Ordinary frames and warming
value updates do not themselves churn this generation. Check the actual
prepared recipe on every commit, so a frame-driven optimization cannot bypass
the policy. An HDR surface tone-mapped to a proven SDR destination is distinct
from an HDR output; qualify that case explicitly or deny it initially.

Audit and route all applicable paths through the same guard:

- `OutputManager.commitOutputState`, including grouped backend commits,
  adaptive-sync retry, display preview/rollback and failure recovery.
- `Output.commitFrameState`, scene construction and full renderer fallback,
  `commitAdaptiveSync`, mirroring and backend-requested state.
- Session/VT transitions, output power, hotplug/removal, renderer reset and
  DRM lease handoff.
- wlroots scene gamma changes and hardware/renderer decisions in patches
  0025/0026, plus any direct output commit found during implementation.

Acquisition and set requests validate immediately on the compositor event loop.
Revalidate before scene construction and immediately before submission against
both live and proposed state. Discard prepared buffers/recipes when their
generation is stale; a post-commit listener is too late to enforce safety.

For a conflicting transition: mark the output transitioning, advance its
generation, revoke incompatible leases internally and cancel queued work
before submission. Remove warming and program the new baseline/color state in
the same tested commit. Where that cannot be atomic, first commit baseline
restoration, then the conflicting transition. Test-only probes must not mutate
ownership. Once a real transition revokes a lease, a failed commit never revives
it or rolls the generation backward.

If removal/restoration fails, do not commit the conflicting state with an old
transform. Keep acquisition blocked, retain truthful last-known state and use
bounded recovery. Disable/blank the output if required to avoid an unsafe
transition; record failures if even that is unavailable. Handle partial backend
group success per output without claiming cross-output atomicity.

Acceptance: deterministic races between requests and every transition reject
stale work before submission, including fallback and rollback commits.

**3. Own composition, calibration and contention**

Represent the baseline independently from warming. Specify the initial transform
order as scene conversion/tone mapping to destination-linear SDR, warming,
then the baseline's output encoding/calibration stages. Validate that order in
the actual renderer seam; an arbitrary LUT/profile cannot be assumed to fit it.
Keep references to original calibration data and compose from that immutable
baseline on each change, avoiding cumulative quantization.

Initial production eligibility accepts only the explicitly qualified baseline
forms. A compositor-established neutral baseline can be the first supported
form. Unknown or externally managed calibration remains ineligible; absence of
a gamma owner does not establish a neutral baseline. Supporting non-neutral
calibration requires a documented pipeline representation, exact stage order
and acceptance evidence before advertising it as supported.

Use one ownership arbiter for native warming and legacy gamma controls. Reject
a competing acquisition as busy, including a second control from the same
client; never destroy another service's control to make room. Do not save an
unknown external LUT and pretend that constitutes calibration preservation.
Calibration changes may trigger safety revocation, but a competitor's request
does not. Reserve ownership through restoration so a new owner cannot race it.

Patch wlroots gamma acquisition and application as necessary to consult this
arbiter and eligibility policy before installing/using a LUT. Unsafe existing
legacy controls must be invalidated before conflicting commits too. Preserve
the legacy wire protocol's generic failure semantics and document any newly
denied cases. The native renderer transform must not be combined with a second
legacy warming LUT accidentally. Carry additive patch/build/ABI changes through
the shell build script and Nix dependency patch list.

Release, client crash and disconnect remove only the warming contribution and
commit the current authorized baseline. Do not restore a saved whole-output
snapshot over a newer calibration, mode or HDR decision. Full damage is required
when installing/removing a renderer transform. Off-screen/powered-off outputs
must resume with baseline before becoming eligible again. A failed restoration
remains visible as restoring/failed; it never becomes a successful off status.

Compositor crash is a separate boundary: no dead process can acknowledge
restoration. Document backend/session cleanup behavior, establish baseline on
the next activation before eligibility, and test compositor termination as well
as Pearl termination. Do not promise immediate physical reset after compositor
crash without evidence from that backend.

Specify capture/mirror behavior as part of qualification. For the first renderer
path, composed output capture includes warming with its normal encoding metadata;
isolated window capture remains independent. Mirrors are initially ineligible
unless their transform placement proves warming is applied exactly once.

Acceptance: supported calibration is unchanged on neutral/release, repeated
adjustments do not accumulate error, and ownership survives failure paths
without takeover or leaked locks.

**4. Report what actually happened**

Emit `committed` only after a successful backend commit carrying that request's
transform, with output identity, generation, request ID, actual path and commit
sequence. Successful acquisition, queueing or output-state testing is never
application success. Reuse the commit/presentation correlation discipline in
`Output.zig` and `DisplayPreview.zig`, including synchronous presentation events.

Optionally emit `presented` for the matching successful presentation event;
advertise when that precision is unavailable. Neither status proves physical
color accuracy. If fallback changes path, only a qualified fallback may retain
the lease, and its result identifies the actual committed path. Otherwise revoke
and recover. Guard delayed callbacks against destroyed leases, new generations,
reused sequence numbers and newer requests.

Expose desired, pending and last-known committed values separately. A failed
update may leave an older warming value active; report it until restoration is
confirmed. Timeouts yield unknown/recovering, never success. Release completion
means baseline committed; physical presentation is a separate optional event.

Document the legacy alternative precisely: gamma advertisement, acquisition and
request submission can establish at most `requested/unconfirmed` while no
generic failure has been received. Roundtrips and elapsed time add no applied
acknowledgment, and generic failure does not reveal its cause. Such a client
still needs compositor-side safety enforcement. Pearl's first production
implementation uses the native contract and retains its unavailable state when
that contract is missing.

Acceptance: fixtures distinguish rejection, test success, commit failure,
fallback, delayed presentation, supersession and confirmed restoration.

**5. Integrate Pearl without changing scheduling ownership**

Work in Pearl's owning repository after the contract stabilizes. Primary files:
`src/platform/wayland/gamma_control.zig`, a proposed native warming binding/service,
`src/services/night_light.zig`, `night_light_policy.zig`, and their existing
settings/control/status adapters. Vendor the exact XML revision and record the
minimum qualified Aqueous package revision.

Map each monitor to its live Wayland output resource and coherent contract
snapshot. Keep one session-owned lease per eligible output; acquire only when
policy requests warming. Coalesce slider/schedule changes, release on off/stop,
cancel pending work on revocation, and reacquire only after a fresh eligible
snapshot. Bound retries; contention does not cause repeated acquisition attempts
or stopping another color service.

Preserve existing civil-time scheduling, temporary overrides, saved preferences,
lock behavior and authenticated settings actions. Treat UI generation checks
and compositor color-generation checks as separate requirements. Lock may
preserve an already safe transform under existing policy; session deactivation
revokes and resume re-evaluates eligibility.

Report each output independently as unavailable, busy, pending, committed,
restoring or failed, with requested and actual values. Aggregate mixed monitors
as partial operation; never label every display active because one succeeded.
Unknown/removed outputs and a lost compositor connection immediately invalidate
application status. Keep `night_light` configuration capability distinct from
runtime display availability and preserve older-server behavior.

Acceptance: extend Pearl's existing Night Light suite for multi-output results,
generation races, resource lifetime, coalescing, contention and older servers.
The absent-contract trace must still contain no gamma acquisition requests.

**6. Validation and release gates**

Add a private native protocol fixture and compositor fault-injection harness.
Keep test overrides out of production qualification. Extend existing
`test-color-pipeline.py`, output retry and display preview regressions where
their real commit/fallback machinery is needed.

| Layer | Required evidence |
| --- | --- |
| State/transform tests | Baseline composition, neutral identity, parameter bounds, generation retirement, arbiter and exactly-once terminal results |
| Protocol fixtures | Snapshot ordering, malformed resources, stale acquisition/set, two clients, legacy/native contention, disconnect and removal |
| Commit fault tests | Queue/set versus HDR/mode/calibration/path transitions; test and real-commit failures; fallback, partial groups, late presentation and restoration failure |
| Software pixels | Warming applied once, full damage on transitions, neutral round trip, supported calibration composition, cursor/capture policy and output isolation |
| Regression builds | Clean pinned wlroots plus full patch stack, Zig ABI/tests, effects on/off, Nix patch parity, existing color/overlay/retry/preview tests |
| Physical acceptance | Qualified SDR GPU/driver/renderer/mode paths, actual warming, baseline restoration, contention, client/compositor death, DPMS, VT/resume, hotplug and mixed SDR/HDR outputs |

Physical comparison must include the final display path: pre-KMS screenshots
cannot validate a hardware LUT or plane transform. Record instrumented baseline,
warmed and restored measurements, and supported calibration preservation.
Define numerical tolerances and recovery deadlines before collecting results;
include precision/clipping checks, visual artifacts and renderer performance.
Mock/headless success remains software evidence only. HDR warming remains
unsupported; test that HDR transitions remove SDR warming safely.

Ship per-path qualification data and explicit deny reasons. Qualification must
identify the tested backend, GPU/driver, renderer, encoding, baseline forms and
mode/format scope; changes outside that scope return unknown/ineligible until
requalified. Install no global advertisement-based bypass. Publish the exact
source/archive/patch/protocol versions, results and unresolved physical limits
for Pearl's dependency handoff.

**Reviewable delivery order**

| Change | Deliverable and exit gate |
| --- | --- |
| 1 | Protocol/specification and state model; binding/fixture agreement |
| 2 | Eligibility guard and shared native/legacy ownership; transition race tests |
| 3 | Renderer warming, baseline composition and restoration; software pixel/failure tests |
| 4 | Commit/presentation status and complete cleanup; truthful lifecycle fixtures |
| 5 | Pearl native client and per-output status behind the production gate; integration suite |
| 6 | Physical qualification, package/protocol pin and documentation; enable only accepted paths |

Changes 2–4 must land together before advertising usable native leases. Pearl's
client and physical harness can develop against a private build after the wire
contract stabilizes. Completion requires both enforcement and recorded physical
acceptance for every enabled path; until then Pearl continues to report warming
unavailable for those outputs.
