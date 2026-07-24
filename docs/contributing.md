# Contributing to Aqueous

Aqueous is implemented in Zig. Format changed Zig files with `zig fmt`, keep
policy code under `compositor/aqueous/wm/`, and keep wlroots/Wayland
integration behind the native compositor API where practical.

Before submitting a change, run:

```sh
cd compositor
scripts/build-wlroots-render-hook.sh
PKG_CONFIG_PATH="$PWD/.deps/wlroots-render-hook/lib/pkgconfig" zig build test
zig build -Dvulkan-effects=false
```

Changes to policy defaults, compositor hooks, output management, or packaging
should also run the relevant headless checks in `compositor/scripts/`.

Configuration readers intentionally accept the existing TOML surface while
producing validated snapshots. Add parser tests for malformed input, defaults,
and compatibility behavior. Layout engines should be deterministic for a
given ordered window snapshot and should cover empty, single-window, and
edge-sized viewports.

Do not add a required external policy, input, or output process. The production
architecture has one required executable. The legacy external policy protocol
is available only through the opt-in `-Dexternal-policy=true` build setting.
