# Aqueous — changes since v0.5.0

This update makes Dank Material Shell the default for the source packages,
adds screen mirroring and more scrolling controls, and improves fullscreen
transitions, multi-monitor reliability, and HDR capture support.

## Desktop and shell integration

- Source packages now default to Seafoam Labs' `dms-aqueous`, including the
  Aqueous Settings plugin, screen-sharing chooser, Spotlight launcher, and
  region screenshots. The prebuilt `PKGBUILD-bin` retains Noctalia; the new
  `gitNoctalia/PKGBUILD` preserves a Noctalia Git package option.
- Improved DMS settings control colors and added integration coverage for the
  shell, settings helper, and packaging.
- Added persistent shell IPC through `AQUEOUS_SOCKET`, with capability discovery,
  snapshots, acknowledged state updates, and typed runtime commands. Existing
  `aqueousctl` commands remain supported. DMS adoption of the new socket is
  still a separate integration step.
- Added native `ext-background-effect-v1` support so compatible applications
  and shells can request blur for precise regions. Global blur settings and
  explicit rule exclusions remain authoritative.

## Window management and input

- Added `open_new_windows_to_right` for scrolling layouts: new windows can open
  immediately beside the focused column. The default remains insertion at the
  far right.
- Added the `scrolling_full_width` window rule to open matching applications
  with a full-width scrolling column. Manual width changes override the rule.
- Mouse-wheel and touchpad scrolling can now bind to built-in actions and custom
  commands using `WheelUp`, `WheelDown`, `WheelLeft`, and `WheelRight`. Existing
  viewport wheel shortcuts can be reassigned or disabled.
- Added the optional `mouse_follows_focus` setting to move the pointer into a
  newly focused window. Pointer-driven interactions avoid triggering a warp.
- Output focus shortcuts now move the pointer to the destination output's
  center and work with empty outputs.
- Improved fullscreen workspace slide transitions, including transparent
  fullscreen content, containment within the correct output, and interrupted
  transitions.

## Displays, rendering, and reliability

- Added screen mirroring with independent refresh rates and aspect-preserving
  letterboxing, configurable through `mirror_of` or the Displays settings page.
  Initial support is limited to one SDR mirror pair on the same backend/device,
  with normal orientation. Mirrors go black while the session is locked or the
  source is unavailable. See the [mirroring guide](docs/screen-mirroring.md).
- Fixed cross-monitor window remapping and explicit-sync buffer release issues
  that could leave windows stalled after being hidden and shown again.
- Added retries with backoff after output rendering or commit failures, allowing
  recovery from transient failures.
- Preserved color-management and Auto HDR state in captured window buffers used
  for workspace transitions and resizing.
- Added FIFO v1 protocol support for client presentation pacing.
- Added an SDR screenshot conversion path for 10-bit HDR outputs, plus native
  10-bit shared-memory format negotiation for ext image-copy capture. Experimental
  `aqueous-capture-color-v1` metadata enables cooperating clients to identify the
  captured color encoding. Native HDR export requires client and encoder support;
  the synchronous conversion fallback is intended for screenshots, with continuous
  recording still requiring further work and validation.
- Added regression coverage for mirroring, output recovery, fullscreen transitions,
  window remapping, wheel bindings, capture formats, and FIFO, plus Proton Wayland
  focus-stall diagnostics.

## Upgrade notes

- **Window rules no longer implicitly select Game Mode.** Omitting `layout`
  preserves the current layout. Add `layout = "game-mode"` to rules that relied
  on the previous behavior. An existing Game Mode workspace claim may need a
  manual layout selection to clear it.
- Existing user configuration is preserved when switching to DMS source
  packages. Update launcher and screenshot commands in
  `~/.config/aqueous/wm.toml` to `dms ipc call spotlight toggle` and
  `dms screenshot region`, including direct screenshot bindings. Compare with
  `/usr/share/aqueous/wm.toml` for the packaged defaults.
- Remove duplicate manual shell startup entries when adopting packaged startup.
  `GitPKGBUILD/PKGBUILD` uses `dms.service`; remove manual enablement of the old
  `aqueous-dms.service` when switching to that variant. Other source variants
  use `aqueous-dms.service`.
- The nested launcher is now `launch_aqueous.sh`, with `AQUEOUS_DMS_CMD` for
  overriding its shell command.
- Rebuild and ship the matching patched wlroots library, then restart Aqueous
  for the new protocol and capture functionality. Diagnostic builds with
  `-Dvulkan-effects=false` also require this patched dependency.

[Full comparison at the reviewed master commit](https://github.com/Seafoam-Labs/Aqueous/compare/v0.5.0...4c48a62a806694301de80284e1325448be7ae377)
