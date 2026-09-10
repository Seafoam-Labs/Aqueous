# Tablet configuration

Aqueous can map a physical tablet's absolute pen input to one output. Pen
pressure, tilt, tip, proximity and buttons continue through tablet-v2; the mouse
cursor remains independent. This needs neither pointer-warp-v1 nor libwacom.

## Generate the configuration

Run these commands inside the Aqueous session:

```sh
aqueousctl input devices --json
aqueousctl input generate-config --device DEVICE_ID --id kamvas-pen --output OUTPUT
aqueousctl input generate-config --device DEVICE_ID --id kamvas-pen --output OUTPUT --write ~/.config/aqueous/input.toml
```

Replace `DEVICE_ID` with the `id` of the device whose `type` is `tablet`, and
`OUTPUT` with an output `name` in the same discovery response. For the **HUION
Kamvas Pro 16 4K**, choose the Kamvas display. For the **Wacom Intuos CTL-490**,
choose the monitor used for drawing; the Intuos has no built-in display.
Repeat with `--id intuos-pen` and the Intuos device ID to configure both tablets.

The second command previews TOML without changing files. The third writes it;
the parent directory must exist. Device IDs are session-local selection handles,
never persistent matchers. The generator chooses exact name/vendor/product
selectors when available, adding udev `ID_PATH` only to distinguish identical
devices. Missing or ambiguous identity data causes an error. Port-bound rules
may need regeneration after moving USB ports.

Output matching prefers a unique `output_edid` identity, falling back to a
connector name when metadata is absent or ambiguous. Despite its historical
name, `output_edid` hashes make/model/serial metadata using Aqueous's existing
outputs.toml algorithm; it is not a hash of raw EDID bytes. A connector-based
assignment may need updating when the connector changes.

`--write` replaces only the tablet rule with the requested `id`, moving it after
other rules so it wins. Other tables and comments remain intact. Writes preserve
permissions and follow an existing symlink to update its target atomically;
dangling symlinks and non-regular files are rejected. New files use mode 0600.
The writer validates supported TOML forms, the tablet rules and their merged
policy, and checks for concurrent changes before replacement. It refuses malformed
or unsupported forms (for example TOML date/time values) rather than rewriting
them. The selected wm configuration is not an input-sidecar destination.

## Rules and precedence

```toml
[[input.tablet]]
id = "drawing-pen"
match_name = "Exact device name from discovery"
output = "DP-1"
```

| Key | Meaning |
| --- | --- |
| `id` | Required unique nonempty rule name. |
| `match_name` | Exact, case-sensitive device name. |
| `match_vendor`, `match_product` | Optional IDs from 0 through 65535, decimal or hexadecimal. |
| `match_path` | Optional exact udev `ID_PATH`, not `/dev/input/eventN`. |
| `enabled` | Defaults to true. False suppresses tablet-tool delivery. |
| `mapping` | Defaults to `"output"`; `"desktop"` opts into the full layout. |
| `output` | Exact connector name. |
| `output_edid` | Alternative `sha256:` identity followed by 64 hexadecimal digits. |

Require a name, a path, or both vendor/product IDs. All supplied matchers must
match the same physical tablet; pointer/touch/pad and virtual devices are excluded.
Enabled output rules require exactly one of `output` and `output_edid`. Desktop
rules must omit both. Disabled rules must omit `mapping`, `output` and
`output_edid`. Strings are bounded to 256 UTF-8 bytes; at most 32 rules may be
present after merging. Unknown keys, duplicate IDs/keys and invalid values are
errors. Use the table/key spelling shown above; the tablet reader follows the
repository's literal table-name convention.

These alternatives can also be generated:

```sh
aqueousctl input generate-config --device DEVICE_ID --id drawing-pen --mapping desktop
aqueousctl input generate-config --device DEVICE_ID --id drawing-pen --disabled
```

Rules can live in wm.toml or input.toml. Each sidecar rule completely replaces an
inherited rule with the same `id` and appends in sidecar order. The last matching
rule wins. Removing a sidecar rule restores the inherited rule on reload.
Unconfigured tablets retain the existing desktop mapping behavior.

Input-sidecar discovery checks `AQUEOUS_INPUT`, `[input].path`, then existing
files at `$XDG_CONFIG_HOME/aqueous/input.toml`, `~/.config/aqueous/input.toml`, and
`/etc/xdg/aqueous/input.toml`, in that order. Discovery reports `input_file`.
The writer reports whether its destination is selected; another destination
does not become active automatically. The normal watcher applies selected-file
writes. No full reload is sent, so reload-triggered commands are not run by the
generator. Native configuration generation requires internal-policy mode.

## Runtime behavior and troubleshooting

Resolved absolute pens use the output's full logical area, including its scale,
rotation/reflection and layout position. Coordinates are clamped inside its
edges. A valid mapping change during proximity waits until proximity-out; lift
the pen beyond detection range to apply it. Output loss or a geometry change
ends an active stroke and releases delivered buttons. A held tip must be released
before drawing resumes. USB reconnects resolve the persistent selectors again.

`aqueousctl input devices --json` reports the winning `rule`, desired connector
or hash, resolved output, `status`, and `pending`. Status values are:

- `resolved`: the configured output is available.
- `waiting_output`: the target is absent, disabled, lacks geometry, or is a mirror.
- `ambiguous_output`: more than one output matches; use a connector selector.
- `disabled`: the winning rule disables this tablet.
- `desktop`: explicit full-layout mapping.
- `unconfigured`: no native rule applies.

Waiting or ambiguous assignments suppress delivery instead of redirecting input
to another monitor. Invalid reloads retain the previous tablet policy and log a
diagnostic. Invalid startup configuration leaves compatibility defaults in place.
`pending: true` means the device's desired mapping has not yet replaced a tool's
current mapping. `relative_tools: true` indicates an observed tablet mouse/lens
tool; absolute mapping does not apply to those relative tools.

Tablet-pad bindings, pressure curves, active-area cropping, relative pen mode,
automatic pen-display association, and a settings GUI are outside this feature.
Clients need tablet-v2 support to receive native pen events. This change does
not add mouse emulation for applications without tablet support. Actual HUION
and Wacom hardware and Xwayland application compatibility still require testing.

## Developer verification

`zig build test` includes parser, overlay, generator and orientation tests.
`zig build test-tablet` runs the shared policy tests alone. For an isolated
two-output integration run from the repository root:

```sh
cd compositor
PKG_CONFIG_PATH="$PWD/.deps/wlroots-render-hook/lib/pkgconfig" zig build -Dvulkan-effects=false -Dtablet-testing=true
cd ..
python3 compositor/scripts/test-tablet.py
```

The fixture requires a C compiler, wayland-scanner, wayland-protocols and the
Wayland client library. It creates a private runtime/configuration directory and
injects in-process wlroots tablet events into the normal input path. It records
tablet-v2 events from native fullscreen clients. The test operation is absent
unless explicitly enabled at build time; do not distribute that test build.
Automated results establish compositor behavior, not physical tablet calibration.
