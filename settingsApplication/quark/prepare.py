#!/usr/bin/env python3
"""Apply narrowly scoped fixes to the pinned Quark source in the build cache."""
import pathlib, shutil, sys
src, dst = map(pathlib.Path, sys.argv[1:])
shutil.copytree(src, dst, dirs_exist_ok=True)
def replace(file, old, new, count=1):
    path = dst / file
    text = path.read_text()
    actual = text.count(old)
    if actual != count:
        raise SystemExit(f'Quark pin mismatch: {file}: expected {count} occurrences, found {actual}')
    path.write_text(text.replace(old, new))
# Do not redispatch a previous action for an unrelated pointer/keyboard event.
replace('window.zig', '        const current_event = input.processEvent(window, event)', '        window.state.last_event = null;\n        const current_event = input.processEvent(window, event)')
# The application intercepts close on its next tick and displays its own prompt.
# Exposed state allows restoring running before the next update without a fork.
replace('Components/TextField.zig', 'max_length: usize = 256,', 'max_length: usize = 1024 * 1024,')
# Translate evdev codes; Wayland wl_keyboard.key is not an XKB keysym.
for key, code in [('BackSpace',14),('Delete',111),('Return',28),('Escape',1),('Home',102),('End',107),('Left',105),('Right',106),('Tab',15)]:
    replace('platforms/wayland.zig', f'xkb.XKB_KEY_{key} =>', f'{code} =>')
# Route non-printable keys through the existing input handler.
replace('input.zig', '            if (textfield) |tf| {\n                if (key_event.mods.ctrl) {', '''            if (key_event.key_code) |code| {
                if (code == .enter and textfield != null and textfield.?.rect.height > 100) {
                    const tf = textfield.?;
                    tf.addChar('\\n') catch {};
                    return .{ .textfield_changed = .{ .id = tf.id, .text = stashEventText(window, tf.getText()) } };
                }
                window.state.last_event = null;
                handleKeyDown(window, code);
                return window.state.last_event;
            }
            if (textfield) |tf| {
                if (key_event.mods.ctrl) {''')
# Tall text fields are multiline editors. Render only visible lines and a caret;
# single-line fields continue using Quark's existing renderer.
replace('renderer/widgets/textfields.zig', '        const pad = 8.0;', '''        if (tf.rect.height > 100) {
            const line_h = font.getTextHeight() + 3;
            const before = tf.text.items[0..@min(tf.cursor_pos, tf.text.items.len)];
            const cursor_line = std.mem.count(u8, before, "\\n");
            const visible: usize = @intFromFloat(@max(1, @floor((tf.rect.height - 16) / line_h)));
            const first = cursor_line -| (visible - 1);
            var lines = std.mem.splitScalar(u8, tf.text.items, '\\n');
            var index: usize = 0;
            while (lines.next()) |line| : (index += 1) {
                if (index < first) continue;
                if (index >= first + visible) break;
                const y = tf.rect.y + 8 + @as(f32, @floatFromInt(index - first)) * line_h;
                const col_start = if (std.mem.lastIndexOfScalar(u8, before, '\\n')) |p| p + 1 else 0;
                const cursor_x = font.getTextWidth(before[col_start..]) catch 0;
                const scroll_x = @max(0, cursor_x - tf.rect.width + 24);
                try text.renderTextClipped(window, font, line, tf.rect.x + 8 - scroll_x,
                    y + font.getLineMetrics().ascent, tf.text_color, tf.rect);
                if (tf.focused and index == cursor_line) {
                    try window.state.renderer.drawRect(.{ .x = tf.rect.x + 8 + cursor_x - scroll_x,
                        .y = y, .width = 2, .height = line_h, .color = tf.text_color }, w_f, h_f);
                }
            }
            continue;
        }
        const pad = 8.0;''')
# Request input devices only after the compositor advertises the capability.
replace('platforms/wayland.zig', '''                    data.pointer = seat.getPointer() catch null;
                    data.keyboard = seat.getKeyboard() catch null;
                    if (data.pointer) |ptr| {
                        ptr.setListener(*WindowState, pointerListener, data);
                    }
                    if (data.keyboard) |kbd| {
                        kbd.setListener(*WindowState, keyboardListener, data);
                    }''', '''                    seat.setListener(*WindowState, seatListener, data);''')
replace('platforms/wayland.zig', 'fn registryListener(', '''fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, data: *WindowState) void {
    switch (event) {
        .capabilities => |ev| {
            if (ev.capabilities.pointer and data.pointer == null) {
                data.pointer = seat.getPointer() catch null;
                if (data.pointer) |ptr| ptr.setListener(*WindowState, pointerListener, data);
            } else if (!ev.capabilities.pointer) {
                if (data.pointer) |ptr| ptr.release();
                data.pointer = null;
            }
            if (ev.capabilities.keyboard and data.keyboard == null) {
                data.keyboard = seat.getKeyboard() catch null;
                if (data.keyboard) |kbd| kbd.setListener(*WindowState, keyboardListener, data);
            } else if (!ev.capabilities.keyboard) {
                if (data.keyboard) |kbd| kbd.release();
                data.keyboard = null;
            }
        },
        else => {},
    }
}

fn registryListener(''')
# Honor initial text (upstream did not pass it to the concrete text field).
replace('layout/instantiate.zig', '            textfield.font = tf.font;', '''            textfield.font = tf.font;
            if (tf.text) |initial| try textfield.setText(initial);
            textfield.cursor_pos = 0;''')
# Cull leaves outside the scroll viewport. They must not draw or receive clicks
# over the fixed action bar. Container layout still includes all children.
replace('State.zig', 'mouse_x: f32 = 0,', 'instantiate_clip: ?@import("Layout.zig") = null,\nmouse_x: f32 = 0,')
replace('layout/instantiate.zig', '    window.state.max_layer = @max(window.state.max_layer, layer);', '''    window.state.max_layer = @max(window.state.max_layer, layer);
    if (window.state.instantiate_clip) |clip| {
        switch (widget_node.*) {
            .column, .row, .scrollview, .overlay, .modal => {},
            inline else => |node| {
                const bounds = node.layout;
                if (bounds.y < clip.y or bounds.y + bounds.height > clip.y + clip.height) return;
            },
        }
    }''')
replace('layout/instantiate.zig', '            try instantiateWidgets(window, sv.child, layer);', '''            const old_clip = window.state.instantiate_clip;
            window.state.instantiate_clip = sv.layout;
            try instantiateWidgets(window, sv.child, layer);
            window.state.instantiate_clip = old_clip;''')
# Fix the scrollbar layer count (both track and handle have a canvas).
replace('layout/instantiate.zig', '''                    handle_canvas,
                );
                try window.state.canvas_layers.append(window.allocator, layer);''', '''                    handle_canvas,
                );
                try window.state.canvas_layers.append(window.allocator, layer);
                try window.state.canvas_layers.append(window.allocator, layer);''')
# Keyboard navigation for multiline editors and all visible form controls.
replace('input.zig', '    tab,\n};', '    tab,\n    up,\n    down,\n};')
replace('platforms/wayland.zig', '                15 => .tab,', '                15 => .tab,\n                103 => .up,\n                108 => .down,')
replace('State.zig', 'focused_textfield_id: ?u32 = null,', 'keyboard_focus_id: ?u32 = null,\nfocused_textfield_id: ?u32 = null,')
replace('input.zig', '            if (key_event.key_code) |code| {', '''            if (key_event.key_code) |code| {
                if (code == .tab) { focusNext(window, key_event.mods.shift); return null; }
                if (window.state.keyboard_focus_id) |id| {
                    for (window.state.dropdowns.items) |dd| {
                        if (dd.id != id or dd.items.len == 0) continue;
                        if (code == .enter or code == .down or code == .up) {
                            const current: usize = dd.selected_index orelse 0;
                            const next = if (code == .up) (current + dd.items.len - 1) % dd.items.len else (current + 1) % dd.items.len;
                            dd.selected_index = @intCast(next);
                            window.state.layout_dirty = true;
                            return .{ .dropdown_changed = .{ .id = id, .index = @intCast(next) } };
                        }
                    }
                    if (code == .enter and textfield == null) {
                        for (window.state.checkboxes.items) |*cb| {
                            if (cb.id == id) {
                                cb.checked = !cb.checked;
                                return .{ .checkbox_toggled = .{ .id = id, .checked = cb.checked } };
                            }
                        }
                        return .{ .button_clicked = id };
                    }
                }
                if (textfield) |tf| {
                    if (tf.rect.height > 100 and (code == .up or code == .down or code == .home or code == .end)) {
                        const pos = @min(tf.cursor_pos, tf.text.items.len);
                        const line_start = if (std.mem.lastIndexOfScalar(u8, tf.text.items[0..pos], '\\n')) |p| p + 1 else 0;
                        const line_end = if (std.mem.indexOfScalarPos(u8, tf.text.items, pos, '\\n')) |p| p else tf.text.items.len;
                        const column = pos - line_start;
                        if (code == .home) tf.cursor_pos = if (key_event.mods.ctrl) 0 else line_start;
                        if (code == .end) tf.cursor_pos = if (key_event.mods.ctrl) tf.text.items.len else line_end;
                        if (code == .up and line_start > 0) {
                            const previous_end = line_start - 1;
                            const previous_start = if (std.mem.lastIndexOfScalar(u8, tf.text.items[0..previous_end], '\\n')) |p| p + 1 else 0;
                            tf.cursor_pos = previous_start + @min(column, previous_end - previous_start);
                        }
                        if (code == .down and line_end < tf.text.items.len) {
                            const next_start = line_end + 1;
                            const next_end = if (std.mem.indexOfScalarPos(u8, tf.text.items, next_start, '\\n')) |p| p else tf.text.items.len;
                            tf.cursor_pos = next_start + @min(column, next_end - next_start);
                        }
                        while (tf.cursor_pos > 0 and tf.cursor_pos < tf.text.items.len and tf.text.items[tf.cursor_pos] & 0xc0 == 0x80) tf.cursor_pos -= 1;
                        if (key_event.mods.shift) { if (tf.selection_start == null) tf.selection_start = pos; tf.selection_end = tf.cursor_pos; }
                        else { tf.selection_start = null; tf.selection_end = null; }
                        return null;
                    }
                }''')
replace('input.zig', '            window.state.mouse_x = mouse_move.x;', '            window.state.keyboard_focus_id = null;\n            window.state.mouse_x = mouse_move.x;')
replace('input.zig', '            if (button.hovered) window.state.cursor = .pointer;', '''            if (window.state.keyboard_focus_id == button.id) button.rect.color = button.hover_color;
            if (button.hovered) window.state.cursor = .pointer;''')
# Geometric tab order follows visible rows, rather than hashed widget IDs.
replace('input.zig', 'pub fn handleKeyDown(window: anytype, key_code: KeyCode) void {', '''fn focusNext(window: anytype, backwards: bool) void {
    const Candidate = struct { id: u32, x: f32, y: f32 };
    var candidates: [512]Candidate = undefined;
    var count: usize = 0;
    inline for (.{ "buttons", "textfields", "checkboxes" }) |field| {
        for (@field(window.state, field).items) |item| {
            if (count == candidates.len) break;
            if (!isInteractionAllowed(window, item.rect.x, item.rect.y)) continue;
            candidates[count] = .{ .id = item.id, .x = item.rect.x, .y = item.rect.y }; count += 1;
        }
    }
    if (count == 0) return;
    std.mem.sort(Candidate, candidates[0..count], {}, struct {
        fn less(_: void, x: Candidate, y: Candidate) bool { return if (@abs(x.y - y.y) < 3) x.x < y.x else x.y < y.y; }
    }.less);
    const current = window.state.keyboard_focus_id orelse window.state.focused_textfield_id;
    var target: usize = if (backwards) count - 1 else 0;
    for (candidates[0..count], 0..) |item, i| if (current == item.id) { target = if (backwards) (i + count - 1) % count else (i + 1) % count; break; };
    const id = candidates[target].id;
    window.state.keyboard_focus_id = id;
    window.state.focused_textfield_id = null;
    for (window.state.textfields.items) |*tf| { tf.focused = tf.id == id; if (tf.focused) window.state.focused_textfield_id = id; }
}

pub fn handleKeyDown(window: anytype, key_code: KeyCode) void {''')
# Bound long menus to the window and let the wheel browse every option.
replace('Widget/Dropdown.zig', 'is_open: bool = false,', 'is_open: bool = false,\nscroll_offset: usize = 0,')
replace('input.zig', '            dd.is_open = !dd.is_open;', '            dd.is_open = !dd.is_open;\n            dd.scroll_offset = dd.selected_index orelse 0;')
for file, loop in [('layout/instantiate.zig','for (dd.items, 0..) |item_text, i| {'),('input.zig','for (dd.items, 0..) |_, i| {')]:
    replace(file, loop, loop + '\n                    if (i < dd.scroll_offset) continue;')
    old = '''const item_y = dd.layout.y +
                        dd.layout.height +
                        item_h * @as(f32, @floatFromInt(i));''' if file.startswith('layout') else '''const item_y = dd.layout.y +
                    dd.layout.height +
                    item_h * @as(f32, @floatFromInt(i));'''
    replace(file, old, '''const visible: usize = @max(1, @as(usize, @intFromFloat(@max(1, @floor((window.height() - 24) / item_h)))));
                    if (i - dd.scroll_offset >= visible) break;
                    const popup_h = item_h * @as(f32, @floatFromInt(@min(visible, dd.items.len - dd.scroll_offset)));
                    const popup_y = @max(12, @min(dd.layout.y + dd.layout.height, window.height() - popup_h - 12));
                    const item_y = popup_y + item_h * @as(f32, @floatFromInt(i - dd.scroll_offset));''')
replace('input.zig', 'pub fn handleMouseScroll(window: anytype, delta: f32) void {', '''pub fn handleMouseScroll(window: anytype, delta: f32) void {
    for (window.state.dropdowns.items) |dd| {
        if (!dd.is_open or dd.items.len == 0) continue;
        dd.scroll_offset = if (delta < 0) @min(dd.scroll_offset + 1, dd.items.len - 1) else dd.scroll_offset -| 1;
        window.state.layout_dirty = true;
        return;
    }''')
