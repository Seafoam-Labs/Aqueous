# Missing Wayland and wlroots protocols

Audit of useful Wayland protocol gaps in Aqueous against the
[wayland-protocols](https://gitlab.freedesktop.org/wayland/wayland-protocols)
and [wlr-protocols](https://gitlab.freedesktop.org/wlroots/wlr-protocols)
registries. Verified against protocol manager creation in
`compositor/aqueous/Server.zig`, `InputManager.zig`, `OutputManager.zig`,
`LayerShell.zig`, `LockManager.zig`, `IdleInhibitManager.zig`,
`WorkspaceManager.zig`, and `XwaylandKeyboardGrab.zig`. Updated September 9,
2026 against the source tree, installed protocol XMLs, and the pinned patched
wlroots 0.20.2 headers. This is a source audit, not a runtime registry probe;
some globals depend on build options or hardware. Dependency support below
refers to this pinned wlroots, not an assertion about upstream development.

## Supported compatibility protocols

`org_kde_kwin_server_decoration_manager` is advertised through wlroots for
GTK 3/4 and older Qt clients. Its display-wide default follows
`[layout].force_ssd`: client-side when disabled and server-side when enabled.
The protocol is obsolete, so its wlroots binding is isolated in
`LegacyServerDecoration.zig` for straightforward removal or replacement.

`keyboard-shortcuts-inhibit-v1` is implemented in
`ShortcutInhibitManager.zig`, with focus/seat eligibility and keyboard dispatch
integration. Normal bindings are inhibited; built-in VT switching remains
reserved. See the [shell contract](../compositor/protocol/aqueous-shell-v1.md).

FIFO v1 is now implemented and advertised by Aqueous with its patched wlroots
dependency. Automated protocol, queue-ordering, lifetime, Pixman/Vulkan pacing,
and syncobj remap tests pass. Physical DRM/VRR and FIFO plane-promotion
qualification remain outstanding; see the
[implementation and validation record](fifo-v1-implementation-plan.md).

## Not supported

### wayland-protocols staging

| Protocol | Global interface | Dependency support | Benefit and required integration |
|---|---|---|---|
| xdg-dialog-v1 | `xdg_wm_dialog_v1` | Present: `wlr_xdg_wm_dialog_v1_create`. | Explicit dialog/modal hints relative to an xdg parent. Integrate placement, stacking, and focus policy, including hint changes and destruction. Clients remain responsible for filtering parent input for modal dialogs. |
| xdg-toplevel-icon-v1 | `xdg_toplevel_icon_manager_v1` | Present: `wlr_xdg_toplevel_icon_manager_v1_create`. | Per-window named or pixel-buffer icons for overviews, switchers, and taskbars. Retain icon state and provide a path for the compositor UI/DMS to consume it; creating the global alone does not display icons. |
| commit-timing-v1 | `wp_commit_timing_manager_v1` | No implementation found. | Earliest presentation timestamps complement FIFO. Add per-commit timing state, ordered readiness gating alongside FIFO/syncobj, and timer-driven output wakeups before scene construction. Use the presentation clock and preserve constraints after timer-object destruction. Conservative gating can precede predictive scheduling. |
| xdg-toplevel-drag-v1 | `xdg_toplevel_drag_manager_v1` | No implementation found. | Move a real toplevel during drag-and-drop, enabling tab detachment and reattachment. Integrate mapping, movement, drop/cancellation, and window lifetime with the existing drag path. |
| xdg-toplevel-tag-v1 | `xdg_toplevel_tag_manager_v1` | No implementation found. | Client-provided tags identify window purposes across launches, improving rules without matching changing titles. Add tag/description storage, rule matching, and inspection/UI exposure. Tags need not be unique; benefit depends on client adoption. |
| xdg-system-bell-v1 | `xdg_system_bell_v1` | Present: `wlr_xdg_system_bell_v1_create`. | Standard audible or visual bell requests. Connect events to configurable feedback, with rate limiting. |
| drm-lease-v1 | `wp_drm_lease_device_v1` (per DRM node) | Present: `wlr_drm_lease_v1.h`. | Lease display resources to clients, useful for directly connected VR headsets. Needs DRM backend wiring, connector-selection policy, request handling, and lease/hotplug lifecycle management. |
| pointer-warp-v1 | `wp_pointer_warp_v1` | No implementation found. | Client requests to reposition a pointer within a surface. Validate focus, enter serial, bounds, and coordinate transforms. Existing internal cursor warping and pointer constraints do not expose this protocol. |
| xdg-session-management-v1 | `xdg_session_manager_v1` | No implementation found. | Restore participating applications' toplevel state across application/compositor restarts. Needs session identity, persistent state, restoration policy, and lifecycle handling. Does not itself relaunch applications or restore their document contents. |
| ext-transient-seat-v1 | `ext_transient_seat_manager_v1` | Present: `wlr_transient_seat_v1.h`. | Temporary independent seats for remote-desktop users. Requires seat creation/destruction and virtual-input routing. `InputManager.zig` currently ignores virtual-pointer seat suggestions, so manager creation is insufficient. |

Protocol definitions are under `staging/<protocol>/<protocol>-v1.xml` in
[wayland-protocols](https://gitlab.freedesktop.org/wayland/wayland-protocols/-/tree/main/staging);
xdg-shell is under `stable/xdg-shell/xdg-shell.xml`. The installed XMLs under
`/usr/share/wayland-protocols` were used to verify interface names and semantics.
The dependency headers are under
`compositor/.deps/wlroots-render-hook/include/wlroots-0.20/wlr/types/`.

### wlr-protocols compatibility

| Protocol | Global interface | Notes |
|---|---|---|
| wlr-input-inhibitor-unstable-v1 | `zwlr_input_inhibit_manager_v1` | Legacy compositor-wide input inhibition. Aqueous already implements ext-session-lock-v1. Low priority unless a concrete compatibility need is identified; would require input-policy integration, not merely global creation. |

### wayland-protocols legacy unstable

| Protocol | Global interface | Notes |
|---|---|---|
| xdg-foreign v1 | `zxdg_exporter_v1` / `zxdg_importer_v1` | Only xdg-foreign v2 is implemented. A few older clients still bind v1. |
| input-timestamps-v1 | `zwp_input_timestamps_manager_v1` | High-resolution timestamps for keyboard/pointer/touch events. Not implemented by wlroots either. |
| tablet v1 | `zwp_tablet_manager_v1` | Superseded by tablet v2 (supported). wlroots only implements v2. |
| fullscreen-shell-v1 | `zwp_fullscreen_shell_manager_v1` | Deprecated; no practical value today. |
| input-panel-v1 | `zwp_input_panel_v1` | Dead protocol; no active users. |
| input-method v1 | `zwp_input_method_v1` | Superseded by input-method v2 (supported). |
| text-input v1 | `zwp_text_input_manager_v1` | Superseded by text-input v3 (supported). |
| text-input v2 | `zwp_text_input_manager_v2` | Superseded by text-input v3 (supported). |

### Deprecated / removed upstream

| Protocol | Global interface | Notes |
|---|---|---|
| wl_shell | `wl_shell` | Removed from wayland.xml; no modern client binds it. |
| xdg-shell-unstable-v5 | `zxdg_shell_v5` | Removed from wayland-protocols. |
| xdg-shell-unstable-v6 | `zxdg_shell_v6` | Removed from wayland-protocols. |
| wl_drm | `wl_drm` | Legacy EGL buffer protocol; superseded by zwp_linux_dmabuf_v1 (supported). |

### Other compositor ecosystems

Not expected for a wlroots-based compositor; listed for completeness.

**KDE Plasma** (wl_registry globals used by Plasma-specific clients):

- `org_kde_plasma_shell` — Plasma panel/shell behavior
- `org_kde_kwin_shadow_manager` — client-drawn shadows
- `org_kde_kwin_appmenu_manager` — global menus
- `org_kde_kwin_blur_manager` — blur
- `org_kde_kwin_idle` — KDE idle tracking
- `org_kde_layer_shell_effects` — Plasma layer-shell window behavior
- `org_kde_plasma_window_management` — Plasma taskbar API

**GNOME / Mutter** — these are D-Bus APIs, not wl_registry globals:

- `org.gnome.Mutter.DisplayConfig`
- `org.gnome.Mutter.IdleMonitor`
- `org.gnome.Mutter.RemoteDesktop`
- `org.gnome.Shell.Screencast`

## Currently supported (verified)

For reference, the protocol set confirmed in the codebase:

**Core:** `wl_compositor` (v6), `wl_subcompositor`, `wl_shm` (v2),
`wl_data_device_manager`, `wl_output`, `wl_seat`.

**Desktop, rendering, and input protocols (mixed stability):** xdg-shell (v7), presentation-time (v2),
viewporter, idle-inhibit-v1, xdg-decoration-v1, relative-pointer-v1,
pointer-constraints-v1, tablet-v2, input-method-v2, text-input-v3,
xdg-activation-v1, xdg-output-v1, linux-dmabuf-v1 (v5), pointer-gestures-v1,
single-pixel-buffer-v1, fractional-scale-v1, cursor-shape-v1 (v2),
tearing-control-v1, alpha-modifier-v1, linux-drm-syncobj-v1,
color-management-v1 (v2/v3), security-context-v1, wayland-fixes,
content-type-v1, fifo-v1.

xdg-shell v7 includes v6 suspension and v7 constrained-edge hints, filtered by
each client's bound version. Suspension follows workspace/output visibility,
locking, and active capture demand; visible previews and outstanding resize
buffers conservatively keep clients active. Edge hints follow client-initiated
resize eligibility, independently of modifier-driven resizing. See the
[implementation and validation record](xdg-shell-v6-v7-implementation-plan.md).

**wayland-protocols ext/staging:** ext-idle-notify-v1, ext-session-lock-v1,
ext-image-copy-capture-v1, ext-output-image-capture-source-v1,
ext-foreign-toplevel-list-v1, ext-foreign-toplevel-image-capture-source-v1,
ext-data-control-manager-v1, ext-workspace-v1, ext-background-effect-v1.

`ext-background-effect-v1` (v1) is available in Vulkan effects builds. Client
regions apply with surface commits and support holes, disconnected components,
popups, and subsurfaces. The global is absent in no-effects builds; capability
events reflect global blur enablement. See the
[native blur plan and implementation notes](native-background-blur-implementation-plan.md).

**wayland-protocols unstable (legacy):** zxdg_decoration_manager_v1,
zxdg_activation_v1, zxdg_foreign_v2, zwp_primary_selection_device_manager_v1,
zwp_data_control_manager_v1, zwp_xwayland_keyboard_grab_manager_v1,
zwp_input_popup_surface_v2.

**wlr-protocols:** zwlr_layer_shell_v1 (v4), zwlr_screencopy_manager_v1,
zwlr_export_dmabuf_manager_v1, zwlr_output_manager_v1,
zwlr_output_power_management_v1, zwlr_gamma_control_manager_v1,
zwlr_foreign_toplevel_manager_v1, zwlr_virtual_pointer_manager_v1,
zwlr_virtual_keyboard_manager_v1, xwayland_shell_v1.

## Recommendations

Effort estimates include useful compositor behavior and validation, not just
advertising protocol globals. Recommended order for general desktop use:

| Priority | Work | Estimated scope |
|---|---|---|
| High | **xdg-dialog-v1** | Small–medium: the dependency implements the protocol; integrate dialog/modal policy. |
| Medium | **xdg-toplevel-icon-v1** | Medium: icon lifetime, rendering, and shell/DMS consumption. |
| Medium | **commit-timing-v1** | Medium–large: surface queue correctness, scheduling, and presentation validation. Existing FIFO is a useful foundation. |
| Medium | **xdg-toplevel-drag-v1** | Medium–large: coordinate drag-and-drop with window movement and lifetime. |
| Medium | **xdg-toplevel-tag-v1** | Small–medium: metadata plus rule/inspection integration; value depends on participating clients. |
| Low; small polish task | **xdg-system-bell-v1** | Small: configurable audible/visual feedback. |

Raise **drm-lease-v1** to high priority for directly connected VR headset
support. Consider **pointer-warp-v1** for applications needing explicit cursor
repositioning, **xdg-session-management-v1** for window-state restoration, and
**ext-transient-seat-v1** for independent remote-desktop users. Session
management and transient seats require broader persistence/input work.

For gaming, commit timing can take precedence over window icons. Resolve
outstanding FIFO, presentation-feedback, and output-retry correctness issues
first. Validate timing/queue interactions with automated tests and actual
presentation timing on DRM hardware; headless tests alone do not qualify it.

content-type-v1 was implemented in the content-type-v1 change: the protocol
global plus policy integration (visual-only `content_type` rule matcher,
auto-HDR game trigger, and aqueousctl exposure).

Missing dependency implementations can be added to Aqueous's pinned wlroots
patch series; upstream support is not a prerequisite. Legacy input inhibition
and superseded protocol versions should be driven by demonstrated client
compatibility needs rather than protocol-count completeness.
