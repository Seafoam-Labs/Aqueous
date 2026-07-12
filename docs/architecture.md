# Aqueous architecture

Aqueous is a single Zig process. `compositor/aqueous/Server.zig` owns wlroots and
Wayland lifecycle; `compositor/aqueous/wm/Aqueous.zig` owns integrated
window-management policy and talks to the compositor through explicit native
hooks in `CompositorApi.zig` and `WindowManager.zig`.

For the detailed event, window, focus, layout, workspace, layer-shell, output,
and render flows, see the
[compositor interaction guide](compositor-interactions.md).

```text
aqueous
├── wlroots/Wayland server and renderer
├── native manage/render cycle
├── layouts, rules, focus, workspaces, and window state
├── XKB/libinput and direct key/pointer actions
├── startup/reload commands and screencopy
└── native output policy and outputd-compatible Unix socket
```

## Repository layout

```text
compositor/
├── build.zig                 # canonical build and Zig tests
├── aqueous/                  # compositor integration
│   └── wm/                   # policy, config, layouts, rules, input, outputs
├── protocol/                 # Wayland protocol definitions
└── scripts/                  # headless integration checks
scripts/build-compositor.sh   # stages bin/aqueous
launch_river.sh               # nested development session
packaging/                    # session hooks and units
PKGBUILD                      # source package
PKGBUILD-bin                  # release-bundle package
```

The River-derived compositor was imported as a subtree; `compositor/ORIGIN.md`
records provenance. There is no live submodule or second repository.

## Policy boundary

Production builds default to internal policy and disable external policy
attachment. `-Dexternal-policy=true` enables the legacy
`river_window_manager_v1` external and compare modes for compatibility testing;
the project no longer ships an external client.

Configuration is parsed into validated snapshots and reloaded on the Wayland
event loop. Manage-cycle hooks collect stable native handles, calculate policy,
and apply geometry/focus/workspace changes before the cycle is committed.
Output changes are staged through `OutputManager.zig` and the existing atomic
wlroots transaction path.

## Build flow

`scripts/build-compositor.sh` runs `zig build` in `compositor/` and stages the
result as `bin/aqueous`. `launch_river.sh`, the Arch package, and release CI all
use the same Zig build. There is no language-runtime side build.

Useful overrides:

| Variable | Effect |
| --- | --- |
| `AQUEOUS_COMPOSITOR_BIN` | Use a prebuilt compositor in the nested launcher. |
| `AQUEOUS_OPTIMIZE` | Zig optimization mode used by the build helper. |
| `AQUEOUS_LINKER_FLAG` | Override the build helper's linker selection. |
| `AQUEOUS_MOD` | Binding modifier (`Super` or `Alt`). |
| `AQUEOUS_NESTED` | Marks a nested development session. |
