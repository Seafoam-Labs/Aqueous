# Tablet output mapping and input.toml configuration

Status: implemented in the source tree, September 10, 2026. Hardware acceptance
for the reported HUION and Wacom devices remains outstanding. See
[Tablet configuration](tablet-configuration.md) for supported syntax and usage.

Implementation uses `compositor/common/tablet.zig` for shared parsing, matching,
serialization and coordinate transforms, `aqueous/TabletMapping.zig` for native
output resolution, and `aqueousctl/Input.zig` for discovery and scoped generation.
Discovery extends the existing in-process output service, requiring no daemon or
new Wayland protocol. A private `-Dtablet-testing=true` build injects wlroots
input events; production builds omit that operation. The design below records
the original contract and acceptance criteria.

## Implementation verification

- Pinned wlroots 0.20.2 and its existing patches rebuilt successfully; no new
  wlroots patch is required.
- 468 unit tests pass, including tablet parsing, inherited-rule replacement,
  precedence, generator identity selection, scoped updates and transforms.
- Private Pixman and Vulkan runs exercise real tablet-v2 delivery from synthetic
  wlroots tablet events, two separately mapped tablets, pressure/tilt/tip/buttons,
  edge confinement, partial axes, all eight transforms at 1x/1.5x/2x with negative
  origins, mouse movement during pen-down, hot reload, output disable/restore,
  USB-style device replacement, and client destruction.
- A real session-lock client checks balanced stroke cancellation and suppression
  of pen focus on desktop clients while locked.
- External-policy mode rejects native generation; production builds reject the
  private input injection operation.
- Scoped file checks cover unchanged stdout previews, idempotence, comments,
  unrelated settings, permissions, symlinks, malformed content and non-regular
  files. Concurrent-change detection uses a final inode/timestamp/content check
  before atomic replacement; it cannot prevent an uncooperative editor writing
  in the narrow interval between that check and rename.
- Physical HUION/Wacom calibration, hardware button quirks, Xwayland applications
  and transformed client-surface qualification remain hardware/application
  acceptance work. Synthetic tests do not substitute for these checks.

## Intended behavior

Allow users to assign a tablet's absolute pen input to one output through
`~/.config/aqueous/input.toml`. Pen positions must remain within that output,
with correct scaling, orientation, pressure, tilt, proximity, and button delivery.
The assignment must survive configuration reloads and device/output reconnects.
`aqueousctl` must be able to generate the necessary input.toml rules from
discovered devices and outputs, so users need not transcribe hardware IDs.

The reported devices are:

- **HUION Kamvas Pro 16 4K:** map the pen to the Kamvas display, keeping the
  pen position aligned with the physical screen.
- **Wacom Intuos CTL-490:** map its drawing area to a user-selected monitor.
  This tablet has no integrated display to identify automatically.

The user reports working behavior in KDE. KWin provides a useful reference:
[`tabletToolPosition()` and `devicePointToGlobalPosition()`](https://github.com/KDE/kwin/blob/master/src/backends/libinput/connection.cpp)
map tablet coordinates to an assigned output, account for output geometry, and
clamp coordinates. Workspace-wide mapping is a separate option; KWin also has
an active-output fallback. Aqueous's explicitly assigned tablets will instead
wait for their configured output when it is unavailable.

This work does not depend on `pointer-warp-v1` or a new client tablet protocol.
It does not require a new input daemon. Automatic display identification,
pressure-curve editing, tablet-pad bindings, relative pen mode, and a settings
GUI are follow-up features. Explicit configuration must work without libwacom.

## Verified starting point

| Component | Existing behavior and implication |
| --- | --- |
| [InputDevice.zig](../compositor/aqueous/InputDevice.zig) | Stores an output pointer and rectangle. Initial backend-suggested output matching handles pointer/touch devices, not tablets. No persistent tablet output selector exists. |
| [TabletTool.zig](../compositor/aqueous/TabletTool.zig) | Owns a separate cursor per tool and sends tablet-v2 events. Applies device mapping when handling position/proximity. During tip-down, surface coordinates are computed using layout-coordinate deltas; audit this for transformed/scaled surfaces. |
| [Seat.zig](../compositor/aqueous/Seat.zig) | Attaches tablets to the seat cursor for event collection. This alone does not convert tablet events into pointer events. |
| [LibinputDevice.zig](../compositor/aqueous/LibinputDevice.zig) | Applies mouse configuration to every non-touchpad libinput device, including tablets. Separate this policy from tablet handling. |
| [Output.zig](../compositor/aqueous/Output.zig) | Output destruction and conversion to a mirror clear device output mappings. A persistent selector must survive those transitions. |
| [wm/config/wm.zig](../compositor/aqueous/wm/config/wm.zig) | Parses mouse, touchpad, and trackpoint sections, but has no tablet rules. Uses bounded configuration snapshots and a custom line-oriented parser. |
| [wm/config/loader.zig](../compositor/aqueous/wm/config/loader.zig) | Parses input.toml separately, then merges input fields into the wm.toml snapshot. Tablet rules need explicit overlay semantics. |
| [wm/CompositorApi.zig](../compositor/aqueous/wm/CompositorApi.zig) | `applyInputConfig()` already applies configuration to connected devices on reload. New-device initialization needs the same tablet resolver. |

Unmapped wlroots absolute input falls back to the full output layout. That
explains desktop-wide pen coordinates without proving duplicate mouse events.
The reported simultaneous mouse behavior remains a separate item to reproduce;
do not assume device names or shared capabilities prove duplicate delivery.

## Proposed configuration contract

Repeatable `[[input.tablet]]` tables are supported. Replace placeholder names
with values reported by the diagnostics command, or use the
`aqueousctl input generate-config` command to produce complete entries.

```toml
# ~/.config/aqueous/input.toml

# HUION Kamvas Pro 16 4K: use the actual pen device name and display connector.
[[input.tablet]]
id = "kamvas-pen"
match_vendor = 0x256c
match_name = "<exact reported HUION pen device name>"
output = "<Kamvas connector name>"

# Wacom Intuos CTL-490: choose the monitor used for drawing.
[[input.tablet]]
id = "intuos-pen"
match_vendor = 0x056a
match_product = 0x033b
output = "<drawing monitor connector name>"
```

The CTL-490 USB identity is supported by the installed libwacom description
`wacom-intuos-s-p2.tablet`; verify it against the actual device. The installed
Kamvas GT1561 description lists multiple possible product IDs and incomplete
metadata, so do not hard-code one as authoritative or match all HUION devices
by vendor alone.

| Key | Semantics |
| --- | --- |
| `id` | Required, unique nonempty rule name, used for sidecar replacement and diagnostics. |
| `match_name` | Optional exact, case-sensitive reported tablet device name. No glob syntax in the first version. |
| `match_vendor`, `match_product` | Optional USB-style vendor/product IDs, each 0–65535. Accept TOML decimal and hexadecimal integers. These selectors require available device identity data. |
| `match_path` | Optional stable udev `ID_PATH`, for distinguishing otherwise identical devices. Do not use `/dev/input/eventN` as persistent identity. |
| `enabled` | Boolean, default `true`. `false` disables matching tablet-tool delivery and needs no output selector. |
| `mapping` | `"output"` by default; `"desktop"` explicitly requests the complete output layout. |
| `output` | Exact connector name. Required for output mapping unless `output_edid` is supplied. |
| `output_edid` | Alternative stable output identity in the existing `sha256:…` format used by outputs.toml. Mutually exclusive with `output`. |

Require `match_name` or both vendor/product IDs or `match_path`; a vendor-only
rule is invalid. All supplied device selectors must match. Consider only
tablet devices, and exclude virtual devices from these physical-device rules.
Supporting virtual tablet drivers requires an explicit future policy.

Use the existing output identity algorithm rather than introducing another
hash. Its current `edid` identifier hashes make/model/serial metadata, not raw
EDID bytes. Document that limitation. Resolve exactly one output; ambiguous
identities remain unresolved rather than choosing whichever output appears first.

For an enabled output-mapping rule, require exactly one output selector. Desktop
mapping must have neither. Disabled rules must omit mapping/output options.
Only pen-like tools are in this absolute mapping contract; preserve existing
tablet mouse/lens relative behavior and report their unsupported mapping mode.

Unconfigured tablets retain existing behavior for compatibility. A configured
tablet must never fall back to desktop mapping because its output is missing.
There is no implicit association between a screenless Intuos and a monitor.

### Overlay, ordering, and errors

- Support the same tables in wm.toml and input.toml. Start with wm.toml rules;
  each sidecar rule replaces the entire rule with the same `id` and is appended
  in sidecar order. Rules with new IDs append normally. No field-by-field merge.
- The last matching rule wins as a whole. A disabled winning rule blocks pen
  delivery; it does not fall through to an earlier rule.
- Removing a sidecar rule restores any inherited wm.toml rule on the next full
  load. Removing all rules from both sources restores the compatibility default.
- Limit the merged collection to 32 rules and use bounded owned strings.
  Diagnose duplicate IDs within one file, overflow, overlong strings, invalid
  types/IDs, unknown tablet keys, and invalid selector combinations.
- Track tablet-policy parse validity separately. On invalid reload, retain the
  previous valid tablet policy and report filename, rule, and reason; do not
  silently drop a restrictive mapping. At startup, report invalid tablet policy
  and leave unconfigured behavior in place. Other existing configuration fields
  keep their current loader semantics. A valid empty policy is an intentional
  reset, distinguishable from a parse failure.

## Implementation design

### 1. Add owned policy and a pure resolver

Introduce tablet rule/config types, preferably in
`compositor/aqueous/wm/config/tablet.zig`, and reference them from `wm.Input`.
Extend the existing parser and loader; avoid replacing the general TOML parser.
Implement typed ID parsing and validation rather than relying on string
unquoting to accept arbitrary values.

Add a pure mapping/resolution helper, preferably `tablet_mapping.zig`, accepting
device identity, configured rules, and output descriptors. Return an explicit
result such as `unconfigured`, `disabled`, `desktop`, `resolved`, `waiting_output`,
or `ambiguous_output`. Keep desired identity separate from any live output pointer.
Use references/slices to the bounded rules where possible; audit snapshot copies
and stack use before adding a large array to frequently passed `wm.Input` values.

### 2. Resolve mappings at device and output lifecycle boundaries

Connect the policy through InputManager/InputDevice and `applyInputConfig()`.
Apply it after device initialization/attachment and after the output layout has
settled. Reevaluate on reload, tablet addition/removal, output addition/removal,
power changes, mirror changes, and output geometry changes. Use deferred
reevaluation at a safe event-loop/manage boundary to avoid reentrant list changes.

Store the selected rule and desired output identity independently of
`config.map_to_output`. Remove live output references before output destruction,
but retain the desired selector for reconnect. Use actual enabled, independently
addressable outputs with valid layout geometry; `policyExposed()` alone is
insufficient because it includes soft-disabled outputs. Mirror-only outputs
are not selectable in this version; report that reason explicitly.

When an assigned output is missing, disabled, or ambiguous, hide the tool cursor
and suppress new pen delivery. Reconnect automatically resolves the same selector.
Do not write runtime session IDs, connector guesses, or event-node numbers into
the user's configuration.

Native tablet policy runs only in internal-policy mode. Preserve external-policy
ownership of the existing input-management mapping requests. Route mapping
changes through a common helper so rectangle/output priority remains consistent;
switching to native output mapping must clear any stale rectangle that would
otherwise override it. Do not introduce a second configuration authority.

### 3. Apply correct absolute coordinates and stroke transitions

Use the mapped output's full logical box, not its usable work area. Preserve
normalized absolute positioning, constrain edge coordinates inside the output,
and retain the last normalized axis when an event supplies only X or Y.
Account for output rotation, fractional scale, and negative layout origins.
Confirm which transforms wlroots/libinput already apply and apply each exactly
once. The initial contract uses the full tablet area stretched over the target;
aspect-preserving cropping and custom active areas are deferred.

Audit hit testing and motion during tip-down. Reuse the compositor's surface
coordinate conversion for transformed/scaled surfaces; simply adding a layout
delta to a surface-local coordinate may be incorrect. Maintain the tablet
implicit grab and pressure/tilt/button ordering.

For a configuration change while a tool is in proximity, retain the old mapping
until proximity-out, provided the output remains usable. Expose the pending
change in diagnostics. Disabling the tool or losing/changing the target geometry
must terminate the old interaction safely: balance delivered tip/button state,
send proximity-out, reset the tool grab/mode, and hide its cursor. Do not resume a
held tip as a new click on another surface; wait for release and a fresh down.
Validate this sequence against wlroots tablet-v2 helpers before implementing it.

### 4. Separate mouse policy and investigate duplicate delivery

Restrict mouse settings in `LibinputDevice.policyApply()` to actual pointer
devices, retaining the current touchpad/trackpoint behavior outside this change.
Tablet positioning must not inherit mouse acceleration or move the seat's mouse
cursor merely because the tablet cursor moves. Preserve ordinary mouse use
alongside a pen, including during a stroke.

Capture source-tagged pointer and tablet events for both physical devices in a
private test session. Distinguish compositor conversion, separate pointer-capable
interfaces, and application-side mouse emulation. Fix any demonstrated duplicate
delivery at its source, and add a reproducer. Do not suppress all same-vendor
pointers or all mice during pen proximity; legitimate devices may share an
interface or group. General mouse fallback for tablet-unaware applications is
outside this mapping change.

### 5. Discover devices and generate configuration with aqueousctl

Add a read-only `aqueousctl input devices --json` command through the existing
IPC/CLI infrastructure. This is a new command, not an existing capability. Report
device selection ID, name/type, vendor/product, stable path when available, seat,
matched rule, desired output, resolved output, mapping status/reason, and deferred changes.
Do not include continuous pen coordinates in ordinary snapshots. Add a bounded
debug mode for source-tagged events only if needed for the duplicate-event test.

Add `aqueousctl input generate-config` using the same discovery snapshot and
policy types. Proposed workflow (device IDs and connector names below are
illustrative, not known identities of the user's hardware):

```sh
aqueousctl input devices --json
aqueousctl outputs --json

# Print a complete [[input.tablet]] entry for the selected device and monitor.
aqueousctl input generate-config --device 12 --output DP-2 --id kamvas-pen
aqueousctl input generate-config --device 15 --output DP-1 --id intuos-pen

# Optionally insert or update that rule in an explicitly selected input.toml.
aqueousctl input generate-config --device 12 --output DP-2 --id kamvas-pen \
  --write "$HOME/.config/aqueous/input.toml"
```

Generator contract:

- Require a device selection and an explicit output selection for output
  mapping. Also accept `--mapping desktop` or `--disabled` as mutually exclusive
  alternatives to `--output`. Never infer which monitor belongs to a Kamvas
  or which monitor an Intuos user intends to draw on.
- Default to printing valid TOML on stdout, with diagnostics on stderr and no
  file or live-state mutation. Require a nonempty `--id` for deterministic rule
  naming and updates. Emit complete rules with no unresolved placeholders.
- Select devices using IDs from the current session's discovery snapshot, but
  serialize persistent matchers only. Prefer reported vendor/product plus the
  exact device name; add `match_path` when needed to distinguish identical
  devices. If no supported selector uniquely identifies the selected tablet,
  fail with an explanation. Device paths may bind the rule to a physical port;
  describe that consequence in the generated comment when used.
- Prefer a unique, available `output_edid` identity for the explicitly selected
  output. Fall back to its exact connector name if metadata is absent or the
  hash is shared by multiple outputs. Explain connector-bound persistence in
  the generated comment. Reject missing, disabled, mirror-only, or stale output
  selections rather than silently selecting another output.
- Use a shared TOML string serializer and tablet-policy validator. Correctly
  escape quotes, backslashes, control characters, and names containing `#` or
  brackets. Extend the custom parser's string decoding as needed so generated
  selectors round-trip exactly; valid TOML alone is not sufficient.
- `--write PATH` creates an input.toml or replaces only the tablet table with
  the same `id`, preserving unrelated settings, comments, and other tablet rules.
  Put the generated rule last, matching the documented last-rule-wins policy;
  repeated identical invocations must not append duplicate rules. Identify table
  spans with TOML-aware parsing, not a regex that can mistake quoted text for a
  table boundary. Refuse ambiguous duplicate IDs or malformed existing content.
- Validate the complete candidate and its effective merged tablet policy before
  writing, including rule limits and whether another rule would override the
  generated assignment. Preserve existing file permissions, use restrictive
  permissions for a new file, and replace atomically. Detect concurrent edits
  and report a conflict without losing changes. Define symlink handling explicitly
  and preserve an existing symlink by updating its resolved target.
- Report the destination and whether it is the compositor's active input sidecar,
  using the existing discovery precedence. An explicit write to another file is
  generation for later use, not a claim that the configuration is active. Do not
  overwrite wm.toml or automatically choose a system-wide configuration path.
- Let the normal configuration watcher apply a write to the active sidecar.
  Report generation/write success separately from application; a deferred stroke
  transition or mapping error remains visible through `input devices --json`.
  Do not issue a full reload automatically, since configured reload actions may
  have unrelated effects. The existing reload command remains available.

Ensure output discovery exposes the identity accepted by `output_edid`. Update
`input.toml.example`, the aqueousctl command reference, and a tablet configuration
guide with both target-device examples, discovery/generation/write commands,
sidecar precedence, reconnect behavior, desktop opt-in, and troubleshooting.
Keep unsupported syntax out of the active example file until the parser/runtime
implementation ships.

## Delivery sequence and checks

1. **Diagnostics and policy contract:** expose device/output identities, capture
   the reported behavior, and implement rule parsing/resolution with unit tests.
   Add TOML generation and scoped file updates using the validated policy types.
2. **Mapping and lifecycle:** connect rules to input/output events, implement
   suspended mappings and stroke transitions, and separate mouse policy.
3. **Coordinate and integration coverage:** validate transformed surfaces and
   implement the private tablet-input fixture. Resolve any reproduced duplication.
4. **Hardware qualification and documentation:** test both named devices and
   publish examples only after behavior is implemented.

Each implementation change must remain reviewable without installing or
restarting the user's running desktop. The plan itself does not require those
actions.

### Automated acceptance

- Parser: multiple tablets, decimal/hex IDs, quoted names, all error cases,
  explicit disable/desktop modes, table ordering, sidecar replacement/removal,
  bounded limits, and preservation of the previous tablet policy on bad reload.
- Resolver: two tablets targeting different outputs; startup with missing output;
  duplicate identities; connect/disconnect/reconnect; disabled and mirror outputs;
  connector change with stable identity; unchanged mouse and unconfigured devices.
- Generator: discovery through TOML generation through the actual loader/resolver
  selects exactly the requested tablet and output. Cover both device examples,
  special-character names, identical devices, missing identity metadata, duplicate
  output hashes, stale selections, disabled/desktop modes, and rule-limit errors.
- File updates: stdout mode changes nothing; writing creates a valid new sidecar
  or updates exactly one rule while preserving unrelated content and permissions.
  Repeating a command is idempotent. Cover inherited rules, malformed files,
  concurrent edits, symlinks, write failures, and inactive destination reporting.
- Coordinates: corners, edges, center, partial-axis events, out-of-range values,
  negative origins, 1x/1.5x/2x scale, rotated/flipped outputs, and transformed
  client surfaces. No pen position can enter a neighboring output.
- Tablet integration: native tablet-v2 client records proximity, motion, pressure,
  tilt, tip, buttons, and cursor changes. Exercise reload during hover/stroke,
  target loss, client destruction, session lock, and two tools independently.
- Pointer coexistence: the same pen sequence produces no compositor-generated
  pointer motion/buttons; a separate mouse remains usable. Any confirmed device
  duplicate path gets its own regression fixture.
- Run normal unit/build checks from [contributing.md](contributing.md), including
  the no-effects build and relevant existing input/configuration tests. Exercise
  the external-policy build to ensure native policy does not override it.

A headless backend does not by itself provide synthetic tablet input. Build the
fixture using in-process wlroots tablet events and an isolated test compositor,
or a private libinput/uinput setup where permissions permit. A virtual-pointer
test cannot establish tablet correctness. Record which path was exercised.

### Hardware acceptance

| Device/scenario | Required result |
| --- | --- |
| Kamvas alongside another monitor | Pen corners/center correspond to the Kamvas screen; no motion or clicks on the other display. Test native resolution and fractional scaling. |
| CTL-490 alongside two monitors | Full active area maps to the configured monitor; switching configuration changes that target predictably. |
| Configuration generation for both tablets | Select each discovered device and its intended output; generate/write rules without editing hardware IDs manually; the normal reload path applies the requested assignments. |
| Each tablet, pressure/tilt-capable native app | Available axes and button behavior remain intact; no double clicks or duplicate strokes. Test an Xwayland app separately and record compatibility limitations. |
| USB reconnect and display reconnect | Stored assignment is restored regardless of device discovery order. |
| Target powered off or removed during a stroke | No stuck tip/button, stale cursor, crash, or input redirected to another monitor. |
| Mouse used while pen is hovering/down | Mouse movement remains independent; pen mapping stays fixed. |

Record actual input identities, output identities, application/backend, and
observed events. Match physical-device behavior against KDE on the same setup
where available; the existing report does not establish whether its session was
Wayland or X11. No physical qualification has been performed in this investigation.

## Scope and estimate

Expected scope is medium: roughly **6–12 engineering days** for explicit mapping,
configuration generation and scoped writes, diagnostics, lifecycle handling,
and automated coverage, plus hardware validation. Coordinate/grab bugs or
confirmed duplicate device streams
can extend that estimate. No wlroots patch is currently known to be necessary;
add one only if the integration tests establish a dependency limitation.

Completion means aqueousctl can generate valid input.toml entries for both
target tablets and optionally update the file without losing other settings.
Both tablets must stay on their assigned outputs, retain their tablet features,
recover correctly from
reload/reconnect, and coexist with an independent mouse. Track automated results
and hardware results separately when updating this document to implemented.
