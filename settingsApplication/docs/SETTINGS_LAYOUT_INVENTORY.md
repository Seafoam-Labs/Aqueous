# Settings layout inventory

DMS reference: local DankMaterialShell source at commit
`aa4b99def48637d86a69620c0a8f3cc6aa0c4092`.
The reference was inspected as source; no DMS reference screenshots were captured.
The screenshots in this directory show the implemented Quark application.

Every backend snapshot field is checked against the actual UI controls by
`tests/test-ui.py`. New unmatched IDs render in Other settings.

Inventory: 221 snapshot fields.

| Page | Section | Field ID |
| --- | --- | --- |
| appearance | Cursor | `desktop.cursor.managed` |
| appearance | Cursor | `desktop.cursor.theme` |
| appearance | Cursor | `desktop.cursor.size` |
| appearance | Desktop typography | `desktop.font.family` |
| appearance | Desktop typography | `desktop.font.style` |
| appearance | Desktop typography | `desktop.font.weight` |
| appearance | Desktop typography | `desktop.font.slant` |
| appearance | Desktop typography | `desktop.font.width` |
| appearance | Desktop typography | `desktop.font.size_pt` |
| appearance | Reserved space | `struts.top` |
| appearance | Reserved space | `struts.bottom` |
| appearance | Reserved space | `struts.left` |
| appearance | Reserved space | `struts.right` |
| appearance | Reserved space | `state.fullscreen_hides_bar` |
| appearance | Reserved space | `state.maximize_full_output` |
| appearance | Backdrop blur | `blur.enabled` |
| appearance | Backdrop blur | `blur.radius` |
| appearance | Backdrop blur | `blur.passes` |
| appearance | Backdrop blur | `blur.noise` |
| appearance | Backdrop blur | `blur.contrast` |
| appearance | Backdrop blur | `blur.brightness` |
| appearance | Backdrop blur | `blur.vibrancy` |
| appearance | Backdrop blur | `blur.vibrancy_darkness` |
| appearance | Window opacity | `opacity.enabled` |
| appearance | Window opacity | `opacity.value` |
| appearance | Window opacity | `opacity.focus_sensitive` |
| appearance | Window opacity | `opacity.focused` |
| appearance | Window opacity | `opacity.unfocused` |
| appearance | Workspace animation | `workspace_transition.enabled` |
| appearance | Workspace animation | `workspace_transition.rate` |
| appearance | System bell | `bell.mode` |
| appearance | System bell | `bell.sound_file` |
| appearance | System bell | `bell.volume` |
| layouts | Default layout and gaps | `layout.default` |
| layouts | Default layout and gaps | `layout.gaps_outer` |
| layouts | Default layout and gaps | `layout.gaps_inner` |
| layouts | Default layout and gaps | `layout.master_ratio` |
| layouts | Default layout and gaps | `layout.master_count` |
| layouts | Window borders | `layout.border_width` |
| layouts | Window borders | `layout.border_focused` |
| layouts | Window borders | `layout.border_normal` |
| layouts | Window borders | `layout.border_urgent` |
| layouts | Window borders | `layout.force_ssd` |
| layouts | Layout shortcuts | `layout.slots.primary` |
| layouts | Layout shortcuts | `layout.slots.secondary` |
| layouts | Layout shortcuts | `layout.slots.tertiary` |
| layouts | Layout shortcuts | `layout.slots.quaternary` |
| layouts | Scrolling layout | `layout.options.scrolling.column_fraction` |
| layouts | Scrolling layout | `layout.options.scrolling.center_focused` |
| layouts | Scrolling layout | `layout.options.scrolling.follow_new_windows` |
| layouts | Scrolling layout | `layout.options.scrolling.open_new_windows_to_right` |
| layouts | Scrolling layout | `layout.options.scrolling.prefer_vertical_on_portrait` |
| layouts | Scrolling layout | `layout.options.scrolling.snap_to_columns` |
| layouts | Scrolling layout | `layout.options.scrolling.allow_overscroll` |
| layouts | Scrolling layout | `layout.options.scrolling.focus_follows_mouse_delay_ms` |
| layouts | Dwindle layouts | `layout.options.dwindle.split_ratio` |
| layouts | Dwindle layouts | `layout.options.dwindle.start_axis` |
| layouts | Dwindle layouts | `layout.options.reverse-dwindle.split_ratio` |
| layouts | Dwindle layouts | `layout.options.reverse-dwindle.start_axis` |
| layouts | Monocle layout | `layout.options.monocle.hide_others` |
| layouts | Monocle layout | `layout.options.monocle.show_borders` |
| layouts | Default layout and gaps | `layout.options.float.placement` |
| layouts | Default layout and gaps | `layout.options.float.cascade_step` |
| layouts | Default layout and gaps | `layout.options.float.move_step` |
| layouts | Default layout and gaps | `layout.options.float.move_step_coarse` |
| layouts | Default layout and gaps | `layout.options.float.resize_step` |
| layouts | Default layout and gaps | `layout.options.float.snap_gap` |
| layouts | Default layout and gaps | `layout.options.float.snap_threshold` |
| layouts | Default layout and gaps | `layout.options.float.resistance` |
| layouts | Default layout and gaps | `layout.options.float.top_edge_maximize` |
| input | Other settings | `input.focus_follows_mouse` |
| input | Other settings | `input.mouse_follows_focus` |
| input | Other settings | `input.focus_new_windows` |
| input | Other settings | `input.raise_on_focus` |
| input | Other settings | `input.raise_on_focus_delay_ms` |
| input | Other settings | `input.pointer_acceleration` |
| input | Other settings | `input.pointer_acceleration_factor` |
| input | Other settings | `input.xkb_layout` |
| input | Other settings | `input.xkb_variant` |
| input | Other settings | `input.xkb_options` |
| input | Other settings | `input.repeat_rate` |
| input | Other settings | `input.repeat_delay` |
| input | Pointer | `input.mouse.accel_profile` |
| input | Pointer | `input.mouse.accel_speed` |
| input | Pointer | `input.mouse.natural_scroll` |
| input | Pointer | `input.mouse.left_handed` |
| input | Pointer | `input.mouse.middle_emulation` |
| input | Touchpad | `input.touchpad.accel_profile` |
| input | Touchpad | `input.touchpad.accel_speed` |
| input | Touchpad | `input.touchpad.natural_scroll` |
| input | Touchpad | `input.touchpad.tap` |
| input | Touchpad | `input.touchpad.dwt` |
| input | Touchpad | `input.touchpad.left_handed` |
| input | Touchpad | `input.touchpad.middle_emulation` |
| input | Touchpad | `input.touchpad.click_method` |
| input | Touchpad | `input.touchpad.scroll_method` |
| displays | Display policy | `display.apply_on_start` |
| displays | Display policy | `display.apply_on_reload` |
| displays | Display policy | `display.fallback_profile` |
| displays | Display policy | `display.identify_by` |
| displays | Display policy | `display.rollback_seconds` |
| rules | Game Mode defaults | `game_mode.remainder_layout` |
| rules | Game Mode defaults | `game_mode.fallback_layout` |
| rules | Game Mode defaults | `game_mode.gaps_inner` |
| keybinds | Other settings | `toggle_start_menu` |
| keybinds | Other settings | `spawn_terminal` |
| keybinds | Other settings | `screenshot` |
| keybinds | Other settings | `close_focused` |
| keybinds | Other settings | `toggle_overview` |
| keybinds | Other settings | `cycle_focus` |
| keybinds | Other settings | `focus_left` |
| keybinds | Other settings | `focus_right` |
| keybinds | Other settings | `focus_up` |
| keybinds | Other settings | `focus_down` |
| keybinds | Other settings | `scroll_viewport_left` |
| keybinds | Other settings | `scroll_viewport_right` |
| keybinds | Other settings | `scroll_viewport_left_arrow` |
| keybinds | Other settings | `scroll_viewport_right_arrow` |
| keybinds | Other settings | `scroll_viewport_up` |
| keybinds | Other settings | `scroll_viewport_down` |
| keybinds | Other settings | `wheel_scroll_left` |
| keybinds | Other settings | `wheel_scroll_right` |
| keybinds | Other settings | `wheel_scroll_up` |
| keybinds | Other settings | `wheel_scroll_down` |
| keybinds | Other settings | `consume_window_into_column` |
| keybinds | Other settings | `expel_window_from_column` |
| keybinds | Other settings | `move_window_left` |
| keybinds | Other settings | `move_window_right` |
| keybinds | Other settings | `move_window_up` |
| keybinds | Other settings | `move_window_down` |
| keybinds | Other settings | `move_column_left` |
| keybinds | Other settings | `move_column_right` |
| keybinds | Other settings | `reload_config` |
| keybinds | Other settings | `reload_rules` |
| keybinds | Other settings | `set_layout_primary` |
| keybinds | Other settings | `set_layout_secondary` |
| keybinds | Other settings | `set_layout_tertiary` |
| keybinds | Other settings | `set_layout_quaternary` |
| keybinds | Other settings | `focus_workspace_1` |
| keybinds | Other settings | `focus_workspace_2` |
| keybinds | Other settings | `focus_workspace_3` |
| keybinds | Other settings | `focus_workspace_4` |
| keybinds | Other settings | `focus_workspace_5` |
| keybinds | Other settings | `focus_workspace_6` |
| keybinds | Other settings | `focus_workspace_7` |
| keybinds | Other settings | `focus_workspace_8` |
| keybinds | Other settings | `focus_workspace_9` |
| keybinds | Other settings | `move_to_workspace_1` |
| keybinds | Other settings | `move_to_workspace_2` |
| keybinds | Other settings | `move_to_workspace_3` |
| keybinds | Other settings | `move_to_workspace_4` |
| keybinds | Other settings | `move_to_workspace_5` |
| keybinds | Other settings | `move_to_workspace_6` |
| keybinds | Other settings | `move_to_workspace_7` |
| keybinds | Other settings | `move_to_workspace_8` |
| keybinds | Other settings | `move_to_workspace_9` |
| keybinds | Other settings | `focus_workspace_up` |
| keybinds | Other settings | `focus_workspace_down` |
| keybinds | Other settings | `focus_previous_workspace` |
| keybinds | Other settings | `move_to_workspace_up` |
| keybinds | Other settings | `move_to_workspace_down` |
| keybinds | Other settings | `focus_output_left` |
| keybinds | Other settings | `focus_output_right` |
| keybinds | Other settings | `move_to_output_left` |
| keybinds | Other settings | `move_to_output_right` |
| keybinds | Other settings | `toggle_fullscreen` |
| keybinds | Other settings | `toggle_maximize` |
| keybinds | Other settings | `toggle_scrolling_full_width` |
| keybinds | Other settings | `toggle_floating` |
| keybinds | Other settings | `raise_window` |
| keybinds | Other settings | `lower_window` |
| keybinds | Other settings | `toggle_always_above` |
| keybinds | Other settings | `toggle_always_below` |
| keybinds | Other settings | `nudge_floating_left` |
| keybinds | Other settings | `nudge_floating_right` |
| keybinds | Other settings | `nudge_floating_up` |
| keybinds | Other settings | `nudge_floating_down` |
| keybinds | Other settings | `nudge_floating_coarse_left` |
| keybinds | Other settings | `nudge_floating_coarse_right` |
| keybinds | Other settings | `nudge_floating_coarse_up` |
| keybinds | Other settings | `nudge_floating_coarse_down` |
| keybinds | Other settings | `resize_floating_left` |
| keybinds | Other settings | `resize_floating_right` |
| keybinds | Other settings | `resize_floating_up` |
| keybinds | Other settings | `resize_floating_down` |
| keybinds | Other settings | `shrink_floating_left` |
| keybinds | Other settings | `shrink_floating_right` |
| keybinds | Other settings | `shrink_floating_up` |
| keybinds | Other settings | `shrink_floating_down` |
| keybinds | Other settings | `snap_left` |
| keybinds | Other settings | `snap_right` |
| keybinds | Other settings | `snap_up` |
| keybinds | Other settings | `snap_down` |
| keybinds | Other settings | `snap_center` |
| keybinds | Other settings | `snap_up_left` |
| keybinds | Other settings | `snap_up_right` |
| keybinds | Other settings | `snap_down_left` |
| keybinds | Other settings | `snap_down_right` |
| keybinds | Other settings | `unsnap` |
| keybinds | Other settings | `cycle_snap_zone` |
| keybinds | Other settings | `cycle_snap_layout` |
| keybinds | Other settings | `cycle_snap_layout_reverse` |
| keybinds | Other settings | `fit_floating_to_output` |
| keybinds | Other settings | `move_floating_to_edge_left` |
| keybinds | Other settings | `move_floating_to_edge_right` |
| keybinds | Other settings | `move_floating_to_edge_up` |
| keybinds | Other settings | `move_floating_to_edge_down` |
| keybinds | Other settings | `grow_floating_to_edge_left` |
| keybinds | Other settings | `grow_floating_to_edge_right` |
| keybinds | Other settings | `grow_floating_to_edge_up` |
| keybinds | Other settings | `grow_floating_to_edge_down` |
| keybinds | Other settings | `toggle_maximize_horizontal` |
| keybinds | Other settings | `toggle_maximize_vertical` |
| keybinds | Other settings | `toggle_minimize` |
| keybinds | Other settings | `unminimize_last` |
| keybinds | Other settings | `lock_screen` |
| keybinds | Other settings | `untrap_pointer` |
| keybinds | Application commands | `actions.toggle_start_menu` |
| keybinds | Application commands | `actions.spawn_terminal` |
| keybinds | Application commands | `actions.screenshot` |
| keybinds | Application commands | `actions.lock_screen` |

## Specialized editors and actions

| Page | Preserved editors and actions |
| --- | --- |
| Overview | Selected live output and workspace layout; immediate switch; file paths and diagnostics |
| Appearance | Installed font family/face and reset; explicit typography/cursor synchronization targets; immediate application theme preference |
| Layouts | Named layouts and zones; add/remove/default; presets; cycle/selection/zone bindings; A–D migration and undo; alias normalization |
| Displays | Arrangement canvas and staged drag; connected refresh; mode, position, scale, transform, mirroring; offline outputs |
| Rules | Ordered rules, add/remove, matching, placement and visual fields |
| Keybinds | Built-in schema chords; custom shortcut add/remove, chord and command |
| Advanced | Six raw files, conflict/recovery details, explicit saved-state reconciliation |
| Shared | Validate, Apply, discard/reload, close confirmation, cancellation, per-page scroll, collapsible sections, global search |

Font family/face use their installed-font editors instead of duplicate schema rows.
All other schema fields use the common descriptive row. Colors retain ARGB and
opacity is displayed as a percentage without changing the canonical 0–1 range.
Search indexes metadata, never raw configuration values.
