# Missing Wayland and wlroots protocols

Audit of Wayland protocol support in Aqueous against the full
[wayland-protocols](https://gitlab.freedesktop.org/wayland/wayland-protocols)
and [wlr-protocols](https://gitlab.freedesktop.org/wlroots/wlr-protocols)
registries. Verified against protocol manager creation in
`compositor/aqueous/Server.zig`, `InputManager.zig`, `OutputManager.zig`,
`LayerShell.zig`, `LockManager.zig`, `IdleInhibitManager.zig`,
`WorkspaceManager.zig`, and `XwaylandKeyboardGrab.zig` (wlroots 0.20).

## Supported compatibility protocols

`org_kde_kwin_server_decoration_manager` is advertised through wlroots for
GTK 3/4 and older Qt clients. Its display-wide default follows
`[layout].force_ssd`: client-side when disabled and server-side when enabled.
The protocol is obsolete, so its wlroots binding is isolated in
`LegacyServerDecoration.zig` for straightforward removal or replacement.

## Not supported

### wayland-protocols stable (wlroots implements these)

| Protocol | Global interface | wlroots implementation | Notes |
|---|---|---|---|
| drm-lease-v1 | `wp_drm_lease_manager_v1` | `wlr.DrmLeaseV1` | Leases DRM connectors to clients. Required for VR headsets (SteamVR, Monado, OpenComposite). Needs DRM backend wiring. |
| keyboard-shortcuts-inhibit-v1 | `zwp_keyboard_shortcuts_inhibit_manager_v1` | `wlr.KeyboardShortcutsInhibitManagerV1` | Lets fullscreen apps (games) receive reserved combos like Alt+Tab. Drop-in. |

### wlr-protocols (wlroots implements this)

| Protocol | Global interface | wlroots implementation | Notes |
|---|---|---|---|
| wlr-input-inhibitor-unstable-v1 | `wlr_input_inhibit_manager` | `wlr.InputInhibitManager` | Compositor-wide keyboard/pointer inhibition. Legacy swaylock used it; superseded by ext-session-lock-v1 (supported), but some older tools still bind it. Drop-in. |

### wayland-protocols staging

| Protocol | Global interface | Notes |
|---|---|---|
| xdg-dialog-v1 | `xdg_dialog_manager_v1` | Dialog/transient window relationships and close-dialog events. KDE and Hyprland implement it; no wlroots implementation yet. |
| xdg-toplevel-drag-v1 | `xdg_toplevel_drag_manager_v1` | Drag a toplevel between outputs/tabs mid-gesture. No wlroots implementation yet. |

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

**wayland-protocols stable:** xdg-shell (v5), presentation-time (v2),
viewporter, idle-inhibit-v1, xdg-decoration-v1, relative-pointer-v1,
pointer-constraints-v1, tablet-v2, input-method-v2, text-input-v3,
xdg-activation-v1, xdg-output-v1, linux-dmabuf-v1 (v5), pointer-gestures-v1,
single-pixel-buffer-v1, fractional-scale-v1, cursor-shape-v1 (v2),
tearing-control-v1, alpha-modifier-v1, linux-drm-syncobj-v1,
color-management-v1 (v2/v3), security-context-v1, wayland-fixes,
content-type-v1.

**wayland-protocols ext/staging:** ext-idle-notify-v1, ext-session-lock-v1,
ext-image-copy-capture-v1, ext-output-image-capture-source-v1,
ext-foreign-toplevel-list-v1, ext-foreign-toplevel-image-capture-source-v1,
ext-data-control-manager-v1, ext-workspace-v1.

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

Priority order among the actionable gaps (all wlroots-ready):

1. **keyboard-shortcuts-inhibit-v1** — easy drop-in; fullscreen games
   currently cannot capture reserved shortcuts.
2. **wlr-input-inhibitor** — easy drop-in; compatibility with older
   lock/overlay tooling.
3. **drm-lease-v1** — moderate effort (DRM backend wiring); the only gap
   with hardware implications (VR headsets).

content-type-v1 was implemented in the content-type-v1 change: the protocol
global plus policy integration (visual-only `content_type` rule matcher,
auto-HDR game trigger, and aqueousctl exposure).

The staging protocols (xdg-dialog-v1, xdg-toplevel-drag-v1) require wlroots
upstream support first. Legacy unstable protocols are superseded or dead and
are not recommended for implementation.
