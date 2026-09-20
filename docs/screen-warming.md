**Screen warming contract**

Aqueous enables experimental `aqueous_output_warming_manager_v1` version 1 in
all compositor builds. Warming is available on live SDR outputs using the Vulkan
renderer with output color-transform support, including physical outputs. No
warming-specific build flag is required. Registry advertisement allows observation;
acquisition still checks each output's current eligibility. HDR warming, mirrors,
unsupported renderers and non-neutral/external calibration remain unsupported.
This is software capability gating, not instrumented physical qualification.

The protocol XML is installed under
`share/aqueous-protocols/experimental/aqueous-output-warming-v1.xml`. Its wire
contract is authoritative. `OutputWarming.zig` owns the typed Wayland handlers,
output generations, leases, eligibility, commit tracking and restoration. It
connects to output lifetime, scene construction, output transactions, session
activity and renderer recovery. Only the wlroots hooks remain in C: patch 0028
adds the shared real-commit veto and legacy gamma acquisition/application guard
without changing the output or output-state struct ABI.

**Identity, ordering and ownership**

Observe a live `wl_output` on the client's Wayland connection. Each complete
`state`/`done` snapshot contains a random session identity, output instance,
color generation, state revision, reason, encoding, baseline/qualification,
owner and committed/pending temperature. High/low words encode 64-bit tokens.
An instance cannot be identified by connector name. Removed observations remain
inert and report removal; their identity is retained. A new output needs a new
observation. Unknown values are unavailable. Generation/revision exhaustion
retires eligibility rather than reusing an authorization token.

Acquire against the snapshot generation. A lease is exclusive across native
warming and legacy gamma. Competing acquisition fails without destroying the
current owner. Manager/observation destruction does not destroy existing leases.
Lease destruction or connection loss initiates restoration. Explicit `release`
keeps the lease resource alive so the client can receive its result. Destroy
inert denied/revoked leases when finished. There is a global bound of 128 protocol
resources; exhausting it disconnects the offending client.

Set/release IDs are nonzero, strictly increasing uint32 values per lease; reuse
or wrap is a protocol error. Native requests accept 2500–6500 K. Algorithm 1
applies destination-linear RGB gains `(1, 1 - 0.25*t, 1 - 0.65*t)`, where
`t = (6500 - K)/4000`, followed by baseline gamma-2.2 encoding. 6500 K is exactly
neutral. Temperature is an adjustment parameter, not a measured white point.
The initial baseline is the compositor's neutral SDR encoding; arbitrary ICC,
3D LUT and external gamma baselines do not become eligible automatically.

**Enforcement and status**

A lease is rechecked before rendering and at the shared wlroots commit boundary,
including grouped backend commits. While warming or restoring, rendering and
software-cursor locks prevent scanout/overlay/offload bypass. Submitted buffers
must match the prepared output generation. Full damage accompanies transform
changes. Test-only output probes never revoke ownership.

Output configuration, modes, HDR/color state, path/mirror changes, session
activity, renderer reset and output removal invalidate authorization. Revocation
cancels queued work before a conflicting real commit. Failed transitions do not
resurrect a lease. Restoration renders the current authorized baseline rather
than replaying a saved output configuration. Ownership and rendering locks stay
reserved until its buffer commits. Power-off does not claim that a baseline frame
was presented; resumption must build a safe buffer. Persistent failure leaves
restoration blocked, with bounded request deadlines and the compositor's existing
output recovery. A conflicting commit with an unprepared buffer is rejected.

Each submitted request gets one terminal result while its resource exists:
committed, rejected, failed, superseded or revoked. `committed` follows a successful
backend commit and includes the request ID, generation, commit sequence and
value. There is **no presentation acknowledgment in version 1**. Testing a state,
acquiring ownership, a Wayland roundtrip, and elapsed time are not proof of
application. Commit acknowledgment also does not measure physical color accuracy.
A failed update can leave its older value visible; snapshots keep the last known
committed value while reporting restoration. Requests time out after two seconds;
timeout reports failure and revokes instead of fabricating success.

Legacy gamma remains advertised, but acquisition/application now uses the same
eligibility and ownership gate. Legacy acquisition is available on eligible SDR
Vulkan outputs in normal builds. An existing color service is never terminated
or displaced to enable Pearl.
Legacy requests retain generic failure and cannot establish more than
requested/unconfirmed status. Pearl uses the native protocol for writes.

Composed output captures include renderer warming in the usual destination
encoding. Isolated window capture is independent. Mirrors are initially
ineligible. Immediate physical restoration after compositor death is not
promised; a new session starts without native warming leases. No physical
calibration/restoration claim follows from virtual-output tests.

**Pearl behavior**

Pearl maps GTK monitors to their actual Wayland output resources on GTK's
connection and waits for complete snapshots. Its session service owns leases,
coalesces targets, preserves scheduling/temporary overrides and keeps existing
session/lock checks. It does not acquire legacy gamma as a fallback. An absent
native contract preserves the old unavailable behavior.

Status distinguishes pending, committed, restoring, unavailable, busy and failed
per output, plus the last known committed value. Mixed results aggregate as
partial. A saved schedule is desired policy, not a display application result.
The first client supports at most 16 concurrent output observations; additional
monitors remain unavailable and cannot make an aggregate all-active claim.

**Validation and release**

Protocol registration and runtime eligibility are independent of build profile,
backend and the Vulkan-effects option. `-Dwarming-testing` has been removed.
Vulkan renderer support is required even in builds with Vulkan effects disabled.
Wire qualification value 1 now describes the supported Vulkan SDR transform path;
it does not assert a measured white point or physical restoration. Physical
acceptance remains unmeasured. Packaging still rejects old artifacts marked with
`warming_testing=true`, along with other private test builds.

Reproduce the checks with a freshly patched dependency and isolated prefixes:

```sh
compositor/scripts/build-wlroots-render-hook.sh /tmp/warming-wlroots
python3 compositor/scripts/test-output-warming.py --prefix /tmp/warming-wlroots
# Build from compositor/ with PKG_CONFIG_PATH and LD_LIBRARY_PATH pointing at
# that prefix. The runtime suite accepts a normal production build; it creates
# its own virtual outputs. Use --renderer pixman to check unsupported-path denial.
python3 compositor/scripts/test-output-warming-runtime.py \
  --compositor /path/to/aqueous --prefix /tmp/warming-wlroots --renderer vulkan
# Add --inject-commit-failure only for a -Doutput-retry-testing=true build.
# Add --pearl /path/to/pearl --pearl-source /path/to/Pearl to exercise the shell.
```

The native Zig handler fixture (`zig build test-output-warming`) mocks renderer
qualification but uses production handlers, real wlroots individual/group commits
and real transform evaluation. It runs with Debug safety checks and the testing
allocator to detect manager and buffer leaks; it does not claim ASan/UBSan coverage
for Zig or wlroots. This separate test target requires private Wayland sockets
and the compositor build dependencies. The runtime
suite uses a real private Vulkan renderer, native Wayland clients, screenshots,
optional commit failure injection, virtual modesets and an isolated Pearl/logind session.
The [validation record](screen-warming-validation.json) includes source hashes,
passed checks and local artifact locations. These are software tests only.
Record physical measurements, supported baseline
forms, GPU/driver/renderer/mode/format scope, VT/DPMS/device-loss behavior and
recovery deadlines before claiming physical qualification. The remaining
acceptance requirements are in [the implementation plan](screen-warming-implementation-plan.md).
