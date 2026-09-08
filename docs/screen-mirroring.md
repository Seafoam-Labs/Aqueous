# Screen mirroring

Aqueous can mirror one output to another output on the same backend/device.
The source retains its resolution, scale, workspace and refresh rate. The
mirror fits the complete source image into its own resolution, preserving the
aspect ratio with black bars. Windows, panels, popups, effects and the cursor
are included.

## Configure a mirror

Add the relationship to `~/.config/aqueous/outputs.toml`, substituting connector
names and advertised modes from `aqueousctl outputs --json`:

```toml
[[output]]
name = "DP-1"
mode = "2560x1440@240"

[[output]]
name = "HDMI-A-1"
mode = "1920x1080@60"
mirror_of = "DP-1"
adaptive_sync = false
hdr = false
transform = "normal"
```

Both outputs must use SDR and normal orientation. The source can retain its
adaptive-sync setting; the destination uses fixed refresh and disallows tearing.
Source and destination rates need not be integer multiples. The compositor
copies frames at destination demand, skips intermediate updates, and retains
the latest complete image when the source is idle.

The settings plugin's Displays page also offers **Extended desktop** and
**Mirror of …** choices. Select the destination and Apply. Mirrored outputs
remain in the display selector but are omitted from the desktop arrangement
canvas. Their position and scale settings are retained for returning to an
extended desktop. Select compatible SDR/orientation/refresh settings before
activating the relationship.

To return to an extended desktop, explicitly clear the relationship:

```toml
[[output]]
name = "HDMI-A-1"
mirror_of = ""
```

An omitted field inherits policy; an empty string clears it. Output profiles
support the same field. The existing output service accepts `mirror_of` in
`set` changes, for example this request to
`$XDG_RUNTIME_DIR/aqueous/outputd.sock`:

```json
{"op":"set","changes":[{"name":"HDMI-A-1","mirror_of":"DP-1","adaptive_sync":false}]}
```

Output-service apply responses describe staged changes; the existing output
transaction performs the backend commit. `aqueousctl outputs --json` includes
`mirror_of`, `mirror_status` and `mirror_error` when the Aqueous output service
is available. Its standard output-management discovery remains available without
that service. Status is `starting`, `active`, `waiting_for_source`, `suspended`,
`error`, or `extended`.

## Lifecycle and limits

The mirror has no independent workspace or pointer area. Existing windows on
that output migrate using output-removal policy; returning to extended mode
creates its workspace space again without automatically moving those windows
back. Mirror outputs cannot be layer-shell or input-device mapping targets.

A disconnected or powered-off source leaves the mirror black until a usable
source returns. The mirror is black during session locking and while locked.
Cached desktop images are discarded on locking, source changes and resizing.
After unlocking, it waits for fresh source content.

The first version supports one mirror pair, SDR, normal transforms, and a
shared output backend/device. Self references, chains, additional pairs and
incompatible source/destination settings are rejected. Vulkan requires timeline
synchronization support; the diagnostic Pixman build is also supported. HDR
mirroring, rotation, cross-device transfer, delay, audio and wireless transport
are outside this version.

Mirroring forces source composition and software cursor rendering and disables
source overlay promotion/direct scanout. It also adds GPU copy and scaling work.
Independent frame scheduling avoids coupling the source to the destination's
refresh; it does not guarantee unchanged game performance. Physical capture-card
cadence, tearing, VRR behavior and performance must be measured on the intended
hardware before relying on them for a production capture setup.

## Validation

Build with `-Doutput-retry-testing=true` for the private regression's fault
injection and committed-buffer pixel probes. The probes are absent in production
builds. They inspect compositor-owned buffers without creating a desktop output
for the mirror.

```sh
python3 compositor/scripts/test-output-mirroring.py \
  --renderer pixman --compositor /path/to/pixman/aqueous --ctl /path/to/aqueousctl
python3 compositor/scripts/test-output-mirroring.py \
  --renderer vulkan --validation --compositor /path/to/vulkan/aqueous --ctl /path/to/aqueousctl
```

Run graphical tests serially. Each starts a private headless compositor with
its own configuration and runtime directory, retaining JSON and logs under the
printed `/tmp/aqueous-output-mirror-*` directory. Dependencies match the existing
output-retry regression: Python/Pillow, C compiler, Wayland development tools,
`grim`, and Vulkan device access for the GPU variant.

Coverage includes pixel comparison, letterboxing, occupied-output migration,
source callbacks, independent configured rates, 1.25 source scale, destination
resizing, 59.94 Hz, rejected relationships, missing sources, session lock/unlock,
repeated toggling, commit-failure recovery, source removal, and CLI discovery.
These headless tests do not measure physical scanout timing.
