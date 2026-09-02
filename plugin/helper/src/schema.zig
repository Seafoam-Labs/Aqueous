const std = @import("std");

pub const protocol_version: u32 = 1;
pub const helper_version = "0.4.0";

pub const FileId = enum(u8) {
    wm,
    layout,
    input,
    outputs,
    rules,
    appearance,

    pub fn name(self: FileId) []const u8 {
        return switch (self) {
            .wm => "wm",
            .layout => "layout",
            .input => "input",
            .outputs => "outputs",
            .rules => "rules",
            .appearance => "appearance",
        };
    }

    pub fn fromName(value: []const u8) ?FileId {
        inline for (std.meta.fields(FileId)) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

pub const file_count = std.meta.fields(FileId).len;

pub const Category = enum {
    appearance,
    layouts,
    input,
    displays,
    rules,
    keybinds,

    pub fn name(self: Category) []const u8 {
        return @tagName(self);
    }
};

pub const Kind = enum {
    boolean,
    integer,
    double,
    string,
    string_list,
    select,
    color,

    pub fn name(self: Kind) []const u8 {
        return @tagName(self);
    }
};

pub const Field = struct {
    id: []const u8,
    category: Category,
    label: []const u8,
    description: []const u8,
    file: FileId,
    section: []const u8,
    key: []const u8,
    kind: Kind,
    default_raw: []const u8,
    min: ?f64 = null,
    max: ?f64 = null,
    options: []const []const u8 = &.{},
    section_aliases: []const []const u8 = &.{},
    advanced: bool = false,
};

const layouts = &.{ "tile", "monocle", "grid", "rows", "dwindle", "reverse-dwindle", "scrolling", "stacking", "game-mode", "composable" };
const game_mode_child_layouts = &.{ "tile", "monocle", "grid", "rows", "dwindle", "reverse-dwindle", "scrolling", "stacking" };
const stacking_sections = &.{ "layout.options.float", "layout.options.floating", "layout.options.stack" };
const accel_profiles = &.{ "flat", "adaptive" };
const click_methods = &.{ "clickfinger", "button-areas" };
const scroll_methods = &.{ "two-finger", "edge", "no-scroll" };

pub const fields = [_]Field{
    t("desktop.font.family", .appearance, "Desktop font", "Font family synchronized across Noctalia, GTK, qt5ct, and qt6ct.", .appearance, "desktop.font", "family", "sans-serif"),
    t("desktop.font.style", .appearance, "Desktop font face", "Installed face within the selected family. Empty uses the toolkit's automatic match.", .appearance, "desktop.font", "style", ""),
    f("desktop.font.weight", .appearance, "Desktop font weight", "Portable font weight selected with the installed face.", .appearance, "desktop.font", "weight", .integer, "400", 1, 1000),
    s("desktop.font.slant", .appearance, "Desktop font slant", "Portable slant selected with the installed face.", .appearance, "desktop.font", "slant", "normal", &.{ "normal", "italic", "oblique" }),
    s("desktop.font.width", .appearance, "Desktop font width", "Portable width selected with the installed face.", .appearance, "desktop.font", "width", "normal", &.{ "ultra-condensed", "extra-condensed", "condensed", "semi-condensed", "normal", "semi-expanded", "expanded", "extra-expanded", "ultra-expanded" }),
    f("desktop.font.size_pt", .appearance, "Desktop font size", "Point size for toolkit UI text. Noctalia maps 12 pt to its default text scale.", .appearance, "desktop.font", "size_pt", .integer, "12", 6, 30),
    f("struts.top", .appearance, "Top reserved space", "Pixels reserved above windows.", .wm, "struts", "top", .integer, "32", 0, 4096),
    f("struts.bottom", .appearance, "Bottom reserved space", "Pixels reserved below windows.", .wm, "struts", "bottom", .integer, "0", 0, 4096),
    f("struts.left", .appearance, "Left reserved space", "Pixels reserved left of windows.", .wm, "struts", "left", .integer, "0", 0, 4096),
    f("struts.right", .appearance, "Right reserved space", "Pixels reserved right of windows.", .wm, "struts", "right", .integer, "0", 0, 4096),
    b("state.fullscreen_hides_bar", .appearance, "Fullscreen hides bar", "Let fullscreen windows use the bar area.", .wm, "state", "fullscreen_hides_bar", true),
    b("state.maximize_full_output", .appearance, "Maximize to full output", "Maximized windows ignore reserved struts.", .wm, "state", "maximize_full_output", false),
    b("blur.enabled", .appearance, "Backdrop blur", "Blur content behind eligible windows.", .wm, "blur", "enabled", false),
    f("blur.radius", .appearance, "Blur radius", "Backdrop blur radius in pixels.", .wm, "blur", "radius", .integer, "5", 0, 128),
    f("blur.passes", .appearance, "Blur passes", "Higher values increase blur and GPU cost.", .wm, "blur", "passes", .integer, "3", 0, 32),
    f("blur.noise", .appearance, "Blur noise", "Stable screen-space noise added to the blurred backdrop.", .wm, "blur", "noise", .double, "0.0", 0, 1),
    f("blur.contrast", .appearance, "Blur contrast", "Contrast applied to the blurred backdrop; 1 is neutral.", .wm, "blur", "contrast", .double, "1.0", 0, 2),
    f("blur.brightness", .appearance, "Blur brightness", "Brightness applied to the blurred backdrop; 1 is neutral.", .wm, "blur", "brightness", .double, "1.0", 0, 2),
    f("blur.vibrancy", .appearance, "Blur vibrancy", "Saturation boost applied to blurred colors.", .wm, "blur", "vibrancy", .double, "0.0", 0, 1),
    f("blur.vibrancy_darkness", .appearance, "Dark-area vibrancy", "How strongly vibrancy affects dark blurred colors.", .wm, "blur", "vibrancy_darkness", .double, "0.0", 0, 1),
    b("opacity.enabled", .appearance, "Window opacity", "Enable compositor-controlled opacity.", .wm, "opacity", "enabled", false),
    f("opacity.value", .appearance, "Window opacity", "Stable opacity when focus sensitivity is disabled.", .wm, "opacity", "value", .double, "0.9", 0, 1),
    b("opacity.focus_sensitive", .appearance, "Focus-sensitive opacity", "Use separate focused and unfocused values.", .wm, "opacity", "focus_sensitive", false),
    f("opacity.focused", .appearance, "Focused opacity", "Opacity of focused windows.", .wm, "opacity", "focused", .double, "1.0", 0, 1),
    f("opacity.unfocused", .appearance, "Unfocused opacity", "Opacity of unfocused windows.", .wm, "opacity", "unfocused", .double, "0.9", 0, 1),
    b("workspace_transition.enabled", .appearance, "Workspace animation", "Animate workspace changes.", .wm, "workspace_transition", "enabled", true),
    f("workspace_transition.rate", .appearance, "Animation rate", "Zero selects the compiled default.", .wm, "workspace_transition", "rate", .double, "0.0", 0, 100),

    s("layout.default", .layouts, "Default layout", "Layout used without a more specific mapping.", .layout, "layout", "default", "tile", layouts),
    f("layout.gaps_outer", .layouts, "Outer gaps", "Pixels between placements and the usable output edge.", .layout, "layout", "gaps_outer", .integer, "8", 0, 512),
    f("layout.gaps_inner", .layouts, "Inner gaps", "Pixels between tiled placements.", .layout, "layout", "gaps_inner", .integer, "4", 0, 512),
    f("layout.master_ratio", .layouts, "Master ratio", "Share of the output assigned to the master area.", .layout, "layout", "master_ratio", .double, "0.55", 0.01, 0.99),
    f("layout.master_count", .layouts, "Master count", "Number of windows in the master area.", .layout, "layout", "master_count", .integer, "1", 1, 64),
    f("layout.border_width", .layouts, "Border width", "Window border width in pixels.", .layout, "layout", "border_width", .integer, "2", 0, 64),
    c("layout.border_focused", .layouts, "Focused border", "ARGB color for focused windows.", .layout, "layout", "border_focused", "0xFF88C0D0"),
    c("layout.border_normal", .layouts, "Normal border", "ARGB color for normal windows.", .layout, "layout", "border_normal", "0xFF3B4252"),
    c("layout.border_urgent", .layouts, "Urgent border", "ARGB color for urgent windows.", .layout, "layout", "border_urgent", "0xFFBF616A"),
    b("layout.force_ssd", .layouts, "Prefer server decorations", "Ask SSD-capable clients to use compositor decorations.", .layout, "layout", "force_ssd", false),
    s("layout.slots.primary", .layouts, "Primary slot", "Layout selected by the primary layout action.", .layout, "layout.slots", "primary", "tile", layouts),
    s("layout.slots.secondary", .layouts, "Secondary slot", "Layout selected by the secondary layout action.", .layout, "layout.slots", "secondary", "scrolling", layouts),
    s("layout.slots.tertiary", .layouts, "Tertiary slot", "Layout selected by the tertiary layout action.", .layout, "layout.slots", "tertiary", "monocle", layouts),
    s("layout.slots.quaternary", .layouts, "Quaternary slot", "Layout selected by the quaternary layout action.", .layout, "layout.slots", "quaternary", "grid", layouts),
    f("layout.options.scrolling.column_fraction", .layouts, "Scrolling column width", "Fraction of usable output width for each column.", .layout, "layout.options.scrolling", "column_fraction", .double, "0.5", 0.01, 0.99),
    b("layout.options.scrolling.center_focused", .layouts, "Center focused column", "Pan to keep the focused column centered.", .layout, "layout.options.scrolling", "center_focused", true),
    b("layout.options.scrolling.follow_new_windows", .layouts, "Follow new windows", "Pan when a new window extends the column order.", .layout, "layout.options.scrolling", "follow_new_windows", true),
    b("layout.options.scrolling.prefer_vertical_on_portrait", .layouts, "Prefer portrait stacks", "Add new windows to a vertical column when this scrolling instance is taller than wide.", .layout, "layout.options.scrolling", "prefer_vertical_on_portrait", false),
    b("layout.options.scrolling.snap_to_columns", .layouts, "Snap viewport", "Quantize manual viewport movement to columns.", .layout, "layout.options.scrolling", "snap_to_columns", false),
    b("layout.options.scrolling.allow_overscroll", .layouts, "Allow overscroll", "Permit edge columns beyond the centered bound.", .layout, "layout.options.scrolling", "allow_overscroll", true),
    f("layout.options.scrolling.focus_follows_mouse_delay_ms", .layouts, "Scrolling pointer focus delay", "Milliseconds the pointer must remain over a scrolling member before keyboard focus follows it; zero is immediate.", .layout, "layout.options.scrolling", "focus_follows_mouse_delay_ms", .integer, "0", 0, 10000),
    f("layout.options.dwindle.split_ratio", .layouts, "Dwindle split", "Fraction assigned to each recursive split.", .layout, "layout.options.dwindle", "split_ratio", .double, "0.5", 0.01, 0.99),
    s("layout.options.dwindle.start_axis", .layouts, "Dwindle start axis", "Direction of the first recursive split.", .layout, "layout.options.dwindle", "start_axis", "vertical", &.{ "vertical", "horizontal" }),
    f("layout.options.reverse-dwindle.split_ratio", .layouts, "Reverse dwindle split", "Fraction assigned to each mirrored recursive split.", .layout, "layout.options.reverse-dwindle", "split_ratio", .double, "0.5", 0.01, 0.99),
    s("layout.options.reverse-dwindle.start_axis", .layouts, "Reverse dwindle start axis", "Direction of the first mirrored recursive split.", .layout, "layout.options.reverse-dwindle", "start_axis", "vertical", &.{ "vertical", "horizontal" }),
    b("layout.options.monocle.hide_others", .layouts, "Hide monocle stack", "Hide non-focused windows in monocle.", .layout, "layout.options.monocle", "hide_others", true),
    b("layout.options.monocle.show_borders", .layouts, "Monocle border", "Draw the configured border in monocle.", .layout, "layout.options.monocle", "show_borders", false),
    stackS("layout.options.float.placement", "Stacking placement", "Policy used for newly opened freeform windows.", "placement", "cascade", &.{ "cascade", "center", "under-pointer", "minimal-overlap" }),
    stackF("layout.options.float.cascade_step", "Cascade step", "Pixel offset between cascaded arrivals.", "cascade_step", .integer, "32", 0, 512),
    stackF("layout.options.float.move_step", "Keyboard move step", "Pixels per fine keyboard movement.", "move_step", .integer, "10", 1, 512),
    stackF("layout.options.float.move_step_coarse", "Coarse move step", "Pixels per coarse keyboard movement.", "move_step_coarse", .integer, "50", 1, 2048),
    stackF("layout.options.float.resize_step", "Keyboard resize step", "Pixels per edge-anchored keyboard resize.", "resize_step", .integer, "10", 1, 512),
    stackF("layout.options.float.snap_gap", "Snap gap", "Inset around committed snap regions.", "snap_gap", .integer, "0", 0, 512),
    stackF("layout.options.float.snap_threshold", "Snap threshold", "Pointer distance from an output edge which activates snapping.", "snap_threshold", .integer, "24", 0, 512),
    stackF("layout.options.float.resistance", "Edge resistance", "Window/output edge attraction distance.", "resistance", .integer, "12", 0, 512),
    stackB("layout.options.float.top_edge_maximize", "Top edge maximizes", "Use the full usable area when a window reaches the top edge.", "top_edge_maximize", true),

    b("input.focus_follows_mouse", .input, "Focus follows pointer", "Focus a window when the pointer enters it.", .input, "input", "focus_follows_mouse", false),
    b("input.focus_new_windows", .input, "Focus new windows", "Give keyboard focus to a newly opened focusable window.", .input, "input", "focus_new_windows", false),
    b("input.raise_on_focus", .input, "Raise focused windows", "Raise a freeform window when it receives focus.", .input, "input", "raise_on_focus", true),
    f("input.raise_on_focus_delay_ms", .input, "Focus raise delay", "Milliseconds to wait before raising a newly focused freeform window.", .input, "input", "raise_on_focus_delay_ms", .integer, "0", 0, 10000),
    b("input.pointer_acceleration", .input, "Pointer acceleration", "Select adaptive pointer acceleration globally.", .input, "input", "pointer_acceleration", false),
    f("input.pointer_acceleration_factor", .input, "Pointer speed", "Global libinput pointer speed.", .input, "input", "pointer_acceleration_factor", .double, "0.0", -1, 1),
    t("input.xkb_layout", .input, "Keyboard layout", "Comma-separated XKB layout names.", .input, "input", "xkb_layout", "us"),
    t("input.xkb_variant", .input, "Keyboard variant", "XKB layout variant.", .input, "input", "xkb_variant", ""),
    t("input.xkb_options", .input, "Keyboard options", "Comma-separated XKB options.", .input, "input", "xkb_options", ""),
    f("input.repeat_rate", .input, "Repeat rate", "Characters per second; zero disables repeat.", .input, "input", "repeat_rate", .integer, "40", 0, 1000),
    f("input.repeat_delay", .input, "Repeat delay", "Milliseconds before keyboard repeat begins.", .input, "input", "repeat_delay", .integer, "400", 0, 10000),
    s("input.mouse.accel_profile", .input, "Mouse acceleration profile", "Libinput acceleration profile for mouse devices.", .input, "input.mouse", "accel_profile", "flat", accel_profiles),
    f("input.mouse.accel_speed", .input, "Mouse speed", "Libinput speed for mouse devices.", .input, "input.mouse", "accel_speed", .double, "0.0", -1, 1),
    b("input.mouse.natural_scroll", .input, "Mouse natural scrolling", "Reverse mouse wheel scrolling.", .input, "input.mouse", "natural_scroll", false),
    b("input.mouse.left_handed", .input, "Left-handed mouse", "Swap primary mouse buttons.", .input, "input.mouse", "left_handed", false),
    b("input.mouse.middle_emulation", .input, "Middle-button emulation", "Emulate a middle button chord.", .input, "input.mouse", "middle_emulation", false),
    s("input.touchpad.accel_profile", .input, "Touchpad acceleration", "Libinput acceleration profile for touchpads.", .input, "input.touchpad", "accel_profile", "adaptive", accel_profiles),
    f("input.touchpad.accel_speed", .input, "Touchpad speed", "Libinput speed for touchpads.", .input, "input.touchpad", "accel_speed", .double, "0.0", -1, 1),
    b("input.touchpad.natural_scroll", .input, "Natural touchpad scrolling", "Move content in the same direction as fingers.", .input, "input.touchpad", "natural_scroll", true),
    b("input.touchpad.tap", .input, "Tap to click", "Use a tap as a primary click.", .input, "input.touchpad", "tap", true),
    b("input.touchpad.dwt", .input, "Disable while typing", "Suppress touchpad motion while typing.", .input, "input.touchpad", "dwt", true),
    b("input.touchpad.left_handed", .input, "Left-handed touchpad", "Swap primary touchpad buttons.", .input, "input.touchpad", "left_handed", false),
    b("input.touchpad.middle_emulation", .input, "Touchpad middle emulation", "Emulate a middle button chord.", .input, "input.touchpad", "middle_emulation", false),
    s("input.touchpad.click_method", .input, "Touchpad click method", "How physical touchpad clicks map to buttons.", .input, "input.touchpad", "click_method", "clickfinger", click_methods),
    s("input.touchpad.scroll_method", .input, "Touchpad scroll method", "How touchpad scrolling is recognized.", .input, "input.touchpad", "scroll_method", "two-finger", scroll_methods),

    b("display.apply_on_start", .displays, "Apply displays at startup", "Apply declarative output policy when Aqueous starts.", .outputs, "display", "apply_on_start", true),
    b("display.apply_on_reload", .displays, "Apply displays on reload", "Apply declarative output policy after config reload.", .outputs, "display", "apply_on_reload", true),
    t("display.fallback_profile", .displays, "Fallback profile", "Named profile used after a rejected output transaction.", .outputs, "display", "fallback_profile", ""),
    s("display.identify_by", .displays, "Display identity", "Compatibility identity field retained by Aqueous.", .outputs, "display", "identify_by", "edid", &.{ "edid", "name" }),
    f("display.rollback_seconds", .displays, "Rollback seconds", "Compatibility rollback timeout.", .outputs, "display", "rollback_seconds", .integer, "0", 0, 65535),

    s("game_mode.remainder_layout", .rules, "Companion layout", "Layout for companion windows beside the anchor.", .rules, "game_mode", "remainder_layout", "grid", game_mode_child_layouts),
    s("game_mode.fallback_layout", .rules, "Fallback layout", "Layout used when Game Mode has no anchor.", .rules, "game_mode", "fallback_layout", "grid", game_mode_child_layouts),
    f("game_mode.gaps_inner", .rules, "Game Mode gap", "Gap between anchor and companion columns.", .rules, "game_mode", "gaps_inner", .integer, "8", 0, 512),

    k("toggle_start_menu", "Super+Space"),
    k("spawn_terminal", "Super+Return"),
    k("screenshot", "Print"),
    k("close_focused", "Super+Q"),
    k("toggle_overview", "Super+W"),
    k("cycle_focus", "Super+Tab"),
    k("focus_left", "Super+H"),
    k("focus_right", "Super+L"),
    k("focus_up", "Super+K"),
    k("focus_down", "Super+J"),
    k("scroll_viewport_left", "Super+Comma"),
    k("scroll_viewport_right", "Super+Period"),
    k("scroll_viewport_left_arrow", "Super+Left"),
    k("scroll_viewport_right_arrow", "Super+Right"),
    k("scroll_viewport_up", "Super+Up"),
    k("scroll_viewport_down", "Super+Down"),
    k("consume_window_into_column", "Super+Ctrl+J"),
    k("expel_window_from_column", "Super+Ctrl+K"),
    k("move_window_left", "Super+Shift+Left"),
    k("move_window_right", "Super+Shift+Right"),
    k("move_window_up", "Super+Shift+Up"),
    k("move_window_down", "Super+Shift+Down"),
    k("move_column_left", ""),
    k("move_column_right", ""),
    k("reload_config", "Super+R"),
    k("reload_rules", ""),
    k("set_layout_primary", ""),
    k("set_layout_secondary", ""),
    k("set_layout_tertiary", ""),
    k("set_layout_quaternary", ""),
    k("focus_workspace_1", "Super+1"),
    k("focus_workspace_2", "Super+2"),
    k("focus_workspace_3", "Super+3"),
    k("focus_workspace_4", "Super+4"),
    k("focus_workspace_5", "Super+5"),
    k("focus_workspace_6", "Super+6"),
    k("focus_workspace_7", "Super+7"),
    k("focus_workspace_8", "Super+8"),
    k("focus_workspace_9", "Super+9"),
    k("move_to_workspace_1", "Super+Shift+1"),
    k("move_to_workspace_2", "Super+Shift+2"),
    k("move_to_workspace_3", "Super+Shift+3"),
    k("move_to_workspace_4", "Super+Shift+4"),
    k("move_to_workspace_5", "Super+Shift+5"),
    k("move_to_workspace_6", "Super+Shift+6"),
    k("move_to_workspace_7", "Super+Shift+7"),
    k("move_to_workspace_8", "Super+Shift+8"),
    k("move_to_workspace_9", "Super+Shift+9"),
    k("focus_workspace_up", "Super+Bracketleft"),
    k("focus_workspace_down", "Super+Bracketright"),
    k("focus_previous_workspace", "Super+BackSpace"),
    k("move_to_workspace_up", "Super+Shift+Bracketleft"),
    k("move_to_workspace_down", "Super+Shift+Bracketright"),
    k("focus_output_left", "Super+Ctrl+Comma"),
    k("focus_output_right", "Super+Ctrl+Period"),
    k("move_to_output_left", "Super+Shift+Comma"),
    k("move_to_output_right", "Super+Shift+Period"),
    k("toggle_fullscreen", "Super+Shift+F"),
    k("toggle_maximize", "Super+Shift+M"),
    k("toggle_scrolling_full_width", "Super+Shift+Z"),
    k("toggle_floating", "Super+Shift+Space"),
    k("raise_window", ""),
    k("lower_window", ""),
    k("toggle_always_above", ""),
    k("toggle_always_below", ""),
    k("nudge_floating_left", ""),
    k("nudge_floating_right", ""),
    k("nudge_floating_up", ""),
    k("nudge_floating_down", ""),
    k("nudge_floating_coarse_left", ""),
    k("nudge_floating_coarse_right", ""),
    k("nudge_floating_coarse_up", ""),
    k("nudge_floating_coarse_down", ""),
    k("resize_floating_left", ""),
    k("resize_floating_right", ""),
    k("resize_floating_up", ""),
    k("resize_floating_down", ""),
    k("shrink_floating_left", ""),
    k("shrink_floating_right", ""),
    k("shrink_floating_up", ""),
    k("shrink_floating_down", ""),
    k("snap_left", ""),
    k("snap_right", ""),
    k("snap_up", ""),
    k("snap_down", ""),
    k("snap_center", ""),
    k("snap_up_left", ""),
    k("snap_up_right", ""),
    k("snap_down_left", ""),
    k("snap_down_right", ""),
    k("unsnap", ""),
    k("cycle_snap_zone", ""),
    k("cycle_snap_layout", ""),
    k("cycle_snap_layout_reverse", ""),
    k("fit_floating_to_output", ""),
    k("move_floating_to_edge_left", ""),
    k("move_floating_to_edge_right", ""),
    k("move_floating_to_edge_up", ""),
    k("move_floating_to_edge_down", ""),
    k("grow_floating_to_edge_left", ""),
    k("grow_floating_to_edge_right", ""),
    k("grow_floating_to_edge_up", ""),
    k("grow_floating_to_edge_down", ""),
    k("toggle_maximize_horizontal", ""),
    k("toggle_maximize_vertical", ""),
    k("toggle_minimize", "Super+N"),
    k("unminimize_last", "Super+Shift+N"),
    k("lock_screen", "Super+Ctrl+L"),
    k("untrap_pointer", "Super+grave"),

    t("actions.toggle_start_menu", .keybinds, "Launcher command", "Command run by the start-menu action.", .wm, "actions", "toggle_start_menu", "noctalia msg panel-toggle launcher"),
    t("actions.spawn_terminal", .keybinds, "Terminal command", "Command run by the terminal action.", .wm, "actions", "spawn_terminal", "ghostty"),
    t("actions.screenshot", .keybinds, "Screenshot command", "Command run by the screenshot action.", .wm, "actions", "screenshot", "grim -g \"$(slurp)\" - | wl-copy"),
    t("actions.lock_screen", .keybinds, "Lock command", "Command run by the lock-screen action.", .wm, "actions", "lock_screen", "noctalia msg lock"),
};

fn f(
    id: []const u8,
    category: Category,
    label: []const u8,
    description: []const u8,
    file: FileId,
    section: []const u8,
    key: []const u8,
    kind: Kind,
    default_raw: []const u8,
    min: ?f64,
    max: ?f64,
) Field {
    return .{ .id = id, .category = category, .label = label, .description = description, .file = file, .section = section, .key = key, .kind = kind, .default_raw = default_raw, .min = min, .max = max };
}

fn b(id: []const u8, category: Category, label: []const u8, description: []const u8, file: FileId, section: []const u8, key: []const u8, default: bool) Field {
    return f(id, category, label, description, file, section, key, .boolean, if (default) "true" else "false", null, null);
}

fn t(id: []const u8, category: Category, label: []const u8, description: []const u8, file: FileId, section: []const u8, key: []const u8, default: []const u8) Field {
    return f(id, category, label, description, file, section, key, .string, default, null, null);
}

fn k(action: []const u8, default: []const u8) Field {
    return f(action, .keybinds, action, "Shortcut for this built-in action.", .wm, "keybinds", action, .string_list, default, null, null);
}

fn s(id: []const u8, category: Category, label: []const u8, description: []const u8, file: FileId, section: []const u8, key: []const u8, default: []const u8, options: []const []const u8) Field {
    var result = t(id, category, label, description, file, section, key, default);
    result.kind = .select;
    result.options = options;
    return result;
}

fn c(id: []const u8, category: Category, label: []const u8, description: []const u8, file: FileId, section: []const u8, key: []const u8, default: []const u8) Field {
    var result = t(id, category, label, description, file, section, key, default);
    result.kind = .color;
    return result;
}

fn stackF(id: []const u8, label: []const u8, description: []const u8, key: []const u8, kind: Kind, default_raw: []const u8, min: ?f64, max: ?f64) Field {
    var result = f(id, .layouts, label, description, .layout, "layout.options.stacking", key, kind, default_raw, min, max);
    result.section_aliases = stacking_sections;
    return result;
}

fn stackB(id: []const u8, label: []const u8, description: []const u8, key: []const u8, default: bool) Field {
    return stackF(id, label, description, key, .boolean, if (default) "true" else "false", null, null);
}

fn stackS(id: []const u8, label: []const u8, description: []const u8, key: []const u8, default: []const u8, options: []const []const u8) Field {
    var result = stackF(id, label, description, key, .string, default, null, null);
    result.kind = .select;
    result.options = options;
    return result;
}

pub fn normalizeLayout(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "float") or std.mem.eql(u8, value, "floating") or std.mem.eql(u8, value, "stack")) return "stacking";
    return value;
}

pub fn find(id: []const u8) ?*const Field {
    for (&fields) |*field| if (std.mem.eql(u8, field.id, id)) return field;
    return null;
}
