const std = @import("std");
const q = @import("quark");
const j = @import("../../model/json.zig");
const model = @import("../../model/shortcuts.zig");
const capture = @import("../../services/shortcut_capture.zig");
const components = @import("settings.zig");

pub fn button(self: anytype, binding: anytype, value: j.Value) !q.Widget {
    const items = if (value == .array) j.items(value) else &[_]j.Value{value};
    const names = try self.ui.allocator().alloc([]const u8, items.len);
    for (items, 0..) |item, i| names[i] = j.str(item);
    const text = try std.mem.join(self.ui.allocator(), " · ", names);
    var widget: q.Widget = .{ .button = q.widget.Button.init(.{
        .content = .{ .text = self.label(if (text.len == 0) "Set shortcut…" else text, false).text },
        .on_action = try self.bind(binding),
        .theme = .{ .height = q.Size.fixed(@max(36, self.theme.font.pixels + 20)) },
    }) };
    widget.button.id = @import("../../model/presentation.zig").stableId(@tagName(binding.kind), binding.key, binding.id, binding.index);
    return widget;
}

pub fn open(self: anytype, binding: anytype, value: j.Value) !void {
    var target = binding;
    target.id = try self.own(binding.id);
    target.key = try self.own(binding.key);
    target.options = &.{};
    target.value = .null;
    target.edited = null;
    self.shortcut_target = target;
    self.shortcut_values = if (value == .array) try j.clone(self.model.allocator(), value) else j.array(self.model.allocator());
    if (value == .string and value.string.len > 0) try self.shortcut_values.array.append(try j.clone(self.model.allocator(), value));
    try record(self, 0);
}

pub fn record(self: anytype, index: usize) !void {
    capture.aq_shortcut_end();
    self.shortcut_index = index;
    self.shortcut_error = "";
    const platform = self.window.state.platform.handle.linux.window_state;
    platform.repeat_event = null;
    platform.key_events.clearRetainingCapacity();
    self.shortcut_recording = capture.aq_shortcut_begin(@ptrCast(platform.display), @ptrCast(platform.surface), @ptrCast(platform.seat)) != 0;
    if (!self.shortcut_recording) self.shortcut_error = "Shortcut recording is unavailable. Focus this window and try Record again.";
    self.rebuilt = true;
}

pub fn close(self: anytype) void {
    capture.aq_shortcut_end();
    self.shortcut_target = null;
    self.shortcut_recording = false;
    self.rebuilt = true;
}

pub fn tick(self: anytype) !void {
    if (!self.shortcut_recording) return;
    var sym: u32 = 0;
    var mods: u32 = 0;
    const state = capture.aq_shortcut_take(&sym, &mods);
    if (state == 0) return;
    capture.aq_shortcut_end();
    self.shortcut_recording = false;
    self.rebuilt = true;
    if (state < 0) {
        self.shortcut_error = "Recording stopped when the window lost focus. Choose Record again to continue.";
        return;
    }
    if (sym == 0xff1b and mods == 0) {
        close(self);
        return;
    }
    const primary = std.c.getenv("AQUEOUS_MOD");
    const alt_primary = if (primary) |value| std.ascii.eqlIgnoreCase(std.mem.span(value), "alt") else false;
    const chord = model.format(self.model.allocator(), sym, mods, alt_primary) catch {
        self.shortcut_error = "Aqueous does not support this key in shortcuts. Choose Record again to try another key.";
        return;
    };
    model.replace(self.model.allocator(), &self.shortcut_values, self.shortcut_index, chord) catch |err| {
        if (err != error.DuplicateShortcut) return err;
        self.shortcut_error = "That shortcut is already in this list. Choose a different combination.";
    };
}

pub fn accept(self: anytype) !void {
    if (self.shortcut_recording or self.shortcut_error.len > 0) return;
    const target = self.shortcut_target orelse return;
    if (target.kind == .field) {
        try self.model.change(target.id, self.shortcut_values);
    } else {
        if (self.shortcut_values.array.items.len != 1) return;
        // Preserve the command and the identity of the existing custom row.
        try self.stageKeybind(target.id, target.key, self.shortcut_values.array.items[0]);
    }
    const key = try self.inputKey(target);
    _ = self.model.inputs.object.swapRemove(key);
    _ = self.model.errors.object.swapRemove(key);
    self.status = "Shortcut changes staged. Apply when ready.";
    close(self);
}

pub fn build(self: anytype, root: *q.widget.Column) !void {
    const target = self.shortcut_target orelse return;
    var dialog = components.card(self.theme.palette, self.theme.radius);
    dialog.tone = 4;
    _ = try dialog.add(self.label("Record shortcut", true));
    _ = try dialog.add(self.richLabel(if (target.kind == .field) j.text(self.model.field(target.id), "label") else "Custom binding", .muted));
    _ = try dialog.add(self.richLabel(if (self.shortcut_recording) "Press and release your key combination. Escape cancels. Desktop shortcuts are paused while recording." else "Choose a shortcut to replace it, or keep the recorded combination. Changes are staged only when you choose Use shortcuts.", .muted));
    for (j.items(self.shortcut_values), 0..) |value, i| {
        var row = self.newRow();
        _ = try row.addWithWidthConstraint(try self.button(j.str(value), .shortcut_record, "existing", i), q.Size.proportional(1));
        if (target.kind == .field) _ = try row.add(try self.button("Remove", .shortcut_remove, "", i));
        _ = try dialog.add(.{ .row = row });
    }
    if (self.shortcut_recording) _ = try dialog.add(self.richLabel(try std.fmt.allocPrint(self.ui.allocator(), "Listening for shortcut {d}…", .{self.shortcut_index + 1}), .accent));
    if (self.shortcut_error.len > 0) _ = try dialog.add(self.richLabel(self.shortcut_error, .error_text));
    var actions = self.newRow();
    _ = try actions.add(try self.button("Cancel", .shortcut_cancel, "", 0));
    if (self.shortcut_recording) {
        _ = try actions.add(try self.button("Stop recording", .shortcut_stop, "", 0));
    } else {
        _ = try actions.add(try self.button("Record again", .shortcut_record, "again", self.shortcut_index));
        if (target.kind == .field) _ = try actions.add(try self.button("Add shortcut", .shortcut_record, "add", self.shortcut_values.array.items.len));
        if (self.shortcut_error.len == 0 and (target.kind == .field or self.shortcut_values.array.items.len == 1)) _ = try actions.add(try self.button("Use shortcuts", .shortcut_accept, "", 0));
    }
    _ = try dialog.add(try self.actionRow(actions));
    if (target.kind == .field and self.shortcut_values.array.items.len == 0) _ = try dialog.add(self.richLabel("No shortcuts: this action will be unbound.", .muted));
    var scroll = try q.widget.ScrollView.initOwned(.{ .column = dialog }, std.heap.page_allocator);
    scroll.id = 202;
    scroll.shrink = true;
    _ = try root.add(.{ .modal = try q.widget.Modal.initOwned(.{ .scrollview = scroll }, true, std.heap.page_allocator) });
}
