# Proton Wayland focus-loss slowdown

The reported workload is Escape from Tarkov under `proton-cachyos-slr`, with:

```sh
PROTON_ENABLE_WAYLAND=1
PROTON_USE_PIPEWIRE=1
__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
```

The user reports desktop-wide lag after switching to another monitor and poor
refresh-rate recovery. This selects Wine's native Wayland driver. XWayland
focus tests alone do not exercise this path. No root cause or production fix
has been established for the reported workload.

## Capture on the affected machine

From a terminal in the affected Aqueous session, with the game running:

```sh
python3 compositor/scripts/collect-focus-stall.py
```

The script prints a temporary artifact directory. During the 30-second capture,
keep the game focused for about five seconds, switch to the other monitor for
ten seconds, then return to the game. It does not change configuration or
launch, close, or focus applications. `--ctl /path/to/aqueousctl` selects a
different diagnostic binary; `--duration 60` allows more time.

The local JSON files contain output modes and adaptive-sync state, window
focus/geometry, query response times, system pressure, and NVIDIA utilization,
VRAM use, clocks and driver version when `nvidia-smi` is available. Queries run
concurrently and time out after two seconds; a timeout is recorded, rather
than preventing later samples. Window titles and monitor identifiers are
included in the CLI snapshots.

Attach these files with the exact Proton build, Aqueous version, game display
mode, monitor refresh rates, and whether refocusing or closing the game restores
responsiveness. Include Aqueous logs covering the same period, especially any
output commit failures, configuration timeouts, or GPU/device errors.

Interpret the capture with these limits:

- An unchanged output mode does not prove presentation is smooth. The mode is
  the configured rate, not the instantaneous VRR frequency.
- Slow or timed-out Aqueous queries indicate that its event loop is delayed,
  or that the diagnostic client itself is delayed. System pressure and driver
  query timing help distinguish those possibilities.
- Prompt Aqueous queries do not rule out GPU presentation stalls. Compare them
  with NVIDIA utilization/VRAM and the observed behavior on both displays.

For a controlled comparison, change only `PROTON_ENABLE_WAYLAND=1` to
`PROTON_ENABLE_WAYLAND=0`, restart the game and repeat the capture. Preserve the
other options, game settings and monitor configuration. This tests the native
Wayland versus XWayland path; it does not by itself assign the fault to Proton,
NVIDIA or Aqueous. Restore the original option afterward. Proton documents
these runtime switches in its [configuration reference](https://github.com/CachyOS/proton-cachyos#proton-cachyos-config-options).

## Local investigation

Headless 60/144 Hz outputs retained independent native-client callback rates
through focus changes under Pixman and Vulkan. A Windows/DXVK probe using the
locally installed `cachyos-11.0-20260703-native` runtime, NVIDIA EGL override and
Proton's Wayland settings also recovered from deliberate background throttling
when placed as a borderless window at Wine's primary-monitor origin. A second
client on the slower output kept animating throughout.

Two earlier probe configurations produced client-side stalls or retained
unfocused state: a decorated window which resized at focus loss, and a
borderless window created outside Wine's primary-monitor origin. These are
not sufficient reproductions of the reported desktop-wide slowdown. Correcting
the probe geometry restored its focus and frame rate without changing Aqueous.

These checks do not run Tarkov, the SLR package, physical DRM outputs, VRR,
or Tarkov's GPU/VRAM workload. They do not establish that the affected user's
configuration is working correctly.
