// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const Overview = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");
const fx = @import("fx.zig");
const LayerSurface = @import("LayerSurface.zig");
const Window = @import("Window.zig");
const Output = @import("Output.zig");
const model = @import("wm/overview/model.zig");
const layout = @import("wm/layout/types.zig");

const log = std.log.scoped(.overview);

pub const backdrop_opacity: f32 = 0.68;
pub const selection_border_width: i32 = 5;
pub const selection_color: [4]f32 = .{ 0.24, 0.72, 1.0, 1.0 };
pub const animation_rate: f64 = 11.0;

tree: *wlr.SceneTree,
output_id: ?u64 = null,
backdrop: ?*wlr.SceneRect = null,
entries: std.ArrayListUnmanaged(Entry) = .empty,
progress: f64 = 1,
hidden_windows: std.ArrayListUnmanaged(HiddenWindow) = .empty,
hidden_layer_surfaces: std.ArrayListUnmanaged(HiddenLayerSurface) = .empty,

const HiddenWindow = struct {
    ref: Window.Ref,
    tree_enabled: bool,
    popup_enabled: bool,
    animation_enabled: bool,
    overview_hidden: bool,
};

const HiddenLayerSurface = struct {
    ref: LayerSurface.Ref,
    tree_enabled: bool,
    popup_enabled: bool,
};

const Borders = struct {
    left: *wlr.SceneRect,
    right: *wlr.SceneRect,
    top: *wlr.SceneRect,
    bottom: *wlr.SceneRect,

    fn create(tree: *wlr.SceneTree) !Borders {
        return .{
            .left = try tree.createSceneRect(0, 0, &selection_color),
            .right = try tree.createSceneRect(0, 0, &selection_color),
            .top = try tree.createSceneRect(0, 0, &selection_color),
            .bottom = try tree.createSceneRect(0, 0, &selection_color),
        };
    }

    fn raiseToTop(borders: Borders) void {
        inline for (.{ "left", "right", "top", "bottom" }) |name| {
            @field(borders, name).node.raiseToTop();
        }
    }

    fn update(borders: Borders, rect: layout.Rect, clip: layout.Rect, selected: bool) void {
        const width: i32 = selection_border_width;
        const horizontal_width = @max(1, rect.width + 2 * width);
        const vertical_height = @max(1, rect.height);
        updateBorderPart(borders.left, .{
            .x = rect.x - width,
            .y = rect.y,
            .width = width,
            .height = vertical_height,
        }, clip, selected);
        updateBorderPart(borders.right, .{
            .x = rect.right(),
            .y = rect.y,
            .width = width,
            .height = vertical_height,
        }, clip, selected);
        updateBorderPart(borders.top, .{
            .x = rect.x - width,
            .y = rect.y - width,
            .width = horizontal_width,
            .height = width,
        }, clip, selected);
        updateBorderPart(borders.bottom, .{
            .x = rect.x - width,
            .y = rect.bottom(),
            .width = horizontal_width,
            .height = width,
        }, clip, selected);
    }

    fn updateBorderPart(node: *wlr.SceneRect, rect: layout.Rect, clip: layout.Rect, selected: bool) void {
        node.node.setEnabled(false);
        if (!selected) return;
        const visible = intersection(rect, clip) orelse return;
        node.node.setPosition(visible.x, visible.y);
        node.setSize(visible.width, visible.height);
        node.node.setEnabled(true);
    }
};

const Entry = struct {
    handle: layout.Handle,
    tree: *wlr.SceneTree,
    buffers: std.ArrayListUnmanaged(Window.OverviewBuffer) = .empty,
    borders: Borders,
    start_rect: layout.Rect,
    target_rect: layout.Rect,
    current_rect: layout.Rect,
    clip_rect: layout.Rect,
    selected: bool = false,

    fn deinit(entry: *Entry) void {
        entry.tree.node.destroy();
        entry.buffers.deinit(util.gpa);
        entry.* = undefined;
    }

    fn update(entry: *Entry, progress: f64) void {
        entry.current_rect = interpolateRect(entry.start_rect, entry.target_rect, progress);
        entry.updateBorders();
        entry.updateBuffers();
    }

    fn updateBorders(entry: *Entry) void {
        entry.borders.update(entry.current_rect, entry.clip_rect, entry.selected);
    }

    fn updateBuffers(entry: *Entry) void {
        const source = entry.start_rect;
        const current = entry.current_rect;
        if (source.width <= 0 or source.height <= 0 or current.width <= 0 or current.height <= 0) {
            for (entry.buffers.items) |record| record.buffer.node.setEnabled(false);
            return;
        }
        const card_clip = intersection(current, entry.clip_rect) orelse {
            for (entry.buffers.items) |record| record.buffer.node.setEnabled(false);
            return;
        };

        const scale_x = @as(f64, @floatFromInt(current.width)) / @as(f64, @floatFromInt(source.width));
        const scale_y = @as(f64, @floatFromInt(current.height)) / @as(f64, @floatFromInt(source.height));
        for (entry.buffers.items) |record| {
            const destination: layout.Rect = .{
                .x = current.x + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(record.x)) * scale_x))),
                .y = current.y + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(record.y)) * scale_y))),
                .width = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(record.dest_width)) * scale_x)))),
                .height = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(record.dest_height)) * scale_y)))),
            };
            const clipped = intersection(destination, card_clip) orelse {
                record.buffer.node.setEnabled(false);
                continue;
            };
            record.buffer.node.setEnabled(true);
            record.buffer.node.setPosition(clipped.x, clipped.y);
            record.buffer.setDestSize(clipped.width, clipped.height);

            const crop_x = clipped.x - destination.x;
            const crop_y = clipped.y - destination.y;
            const transformed_width = if (transformSwapsAxes(record.transform)) record.source.height else record.source.width;
            const transformed_height = if (transformSwapsAxes(record.transform)) record.source.width else record.source.height;
            const transformed_crop: wlr.FBox = .{
                .x = @as(f64, @floatFromInt(crop_x)) * transformed_width / @as(f64, @floatFromInt(destination.width)),
                .y = @as(f64, @floatFromInt(crop_y)) * transformed_height / @as(f64, @floatFromInt(destination.height)),
                .width = @as(f64, @floatFromInt(clipped.width)) * transformed_width / @as(f64, @floatFromInt(destination.width)),
                .height = @as(f64, @floatFromInt(clipped.height)) * transformed_height / @as(f64, @floatFromInt(destination.height)),
            };
            var source_crop: wlr.FBox = undefined;
            source_crop.transform(
                &transformed_crop,
                inverseTransform(record.transform),
                transformed_width,
                transformed_height,
            );
            source_crop.x += record.source.x;
            source_crop.y += record.source.y;
            record.buffer.setSourceBox(&source_crop);
        }
    }
};

pub fn init(overview: *Overview) !void {
    const tree = try server.scene.normal_tree.createSceneTree();
    tree.node.setEnabled(false);
    overview.* = .{ .tree = tree };
}

pub fn deinit(overview: *Overview) void {
    overview.hide();
    overview.tree.node.destroy();
    overview.entries.deinit(util.gpa);
    overview.hidden_windows.deinit(util.gpa);
    overview.hidden_layer_surfaces.deinit(util.gpa);
    overview.* = undefined;
}

/// Build a frozen overview transactionally. Successfully cloned cards are
/// compacted to the front of `cards`; `selected` is repaired if its card was
/// skipped. The returned length is the visual/logical membership to retain.
pub fn show(
    overview: *Overview,
    output: *Output,
    output_box: wlr.Box,
    cards: []model.Card,
    selected: *layout.Handle,
) !usize {
    overview.hide();
    errdefer overview.hide();
    try overview.entries.ensureTotalCapacity(util.gpa, cards.len);

    const backdrop_color: [4]f32 = .{ 0, 0, 0, if (fx.anim_enabled) 0 else backdrop_opacity };
    const backdrop = try overview.tree.createSceneRect(
        output_box.width,
        output_box.height,
        &backdrop_color,
    );
    backdrop.node.setPosition(output_box.x, output_box.y);
    overview.backdrop = backdrop;
    const output_rect: layout.Rect = .{
        .x = output_box.x,
        .y = output_box.y,
        .width = output_box.width,
        .height = output_box.height,
    };

    var accepted: usize = 0;
    for (cards, 0..) |card, index| {
        if (card.source.width <= 0 or card.source.height <= 0 or
            card.target.width <= 0 or card.target.height <= 0)
        {
            continue;
        }
        const ref: Window.Ref = @bitCast(card.handle);
        const window = ref.get() orelse continue;
        const entry_tree = overview.tree.createSceneTree() catch return error.OutOfMemory;
        var entry: Entry = .{
            .handle = card.handle,
            .tree = entry_tree,
            .borders = Borders.create(entry_tree) catch {
                entry_tree.node.destroy();
                return error.OutOfMemory;
            },
            .start_rect = card.source,
            .target_rect = card.target,
            .current_rect = if (fx.anim_enabled) card.source else card.target,
            .clip_rect = output_rect,
        };
        window.cloneOverviewInto(util.gpa, entry_tree, &entry.buffers) catch |err| {
            log.warn("skipping overview window {}: {}", .{ card.handle, err });
            entry.deinit();
            continue;
        };
        entry.borders.raiseToTop();
        entry.update(if (fx.anim_enabled) 0 else 1);
        overview.entries.appendAssumeCapacity(entry);
        cards[accepted] = cards[index];
        accepted += 1;
    }
    if (accepted == 0) return error.NoUsableWindows;
    if (!containsEntry(overview.entries.items, selected.*)) selected.* = overview.entries.items[0].handle;

    overview.output_id = output.policyId();
    overview.progress = if (fx.anim_enabled) 0 else 1;
    overview.setSelected(selected.*);
    overview.tree.node.raiseToTop();
    try overview.hideOutputScene(output);
    overview.tree.node.setEnabled(true);
    return accepted;
}

pub fn setSelected(overview: *Overview, handle: layout.Handle) void {
    for (overview.entries.items) |*entry| {
        entry.selected = entry.handle == handle;
        entry.updateBorders();
    }
}

pub fn remove(overview: *Overview, handle: layout.Handle) void {
    for (overview.entries.items, 0..) |entry, index| {
        if (entry.handle != handle) continue;
        var removed = overview.entries.orderedRemove(index);
        removed.deinit();
        if (overview.entries.items.len == 0) overview.hide();
        return;
    }
}

pub fn hide(overview: *Overview) void {
    overview.tree.node.setEnabled(false);
    overview.restoreOutputScene();
    for (overview.entries.items) |*entry| entry.deinit();
    overview.entries.clearRetainingCapacity();
    if (overview.backdrop) |backdrop| backdrop.node.destroy();
    overview.backdrop = null;
    overview.output_id = null;
    overview.progress = 1;
}

/// Hide only content owned by the overview output. Scene layer roots span all
/// outputs, so disabling those roots would incorrectly blank a second monitor.
/// Background layer surfaces remain visible; their popups do not.
fn hideOutputScene(overview: *Overview, output: *Output) !void {
    std.debug.assert(overview.hidden_windows.items.len == 0);
    std.debug.assert(overview.hidden_layer_surfaces.items.len == 0);

    if (output.active_workspace) |active_workspace| {
        var windows = active_workspace.windows.iterator(.forward);
        while (windows.next()) |window| {
            try overview.hidden_windows.append(util.gpa, .{
                .ref = window.ref,
                .tree_enabled = window.tree.node.enabled,
                .popup_enabled = window.popup_tree.node.enabled,
                .animation_enabled = window.anim_tree.node.enabled,
                .overview_hidden = window.overview_hidden,
            });
            window.overview_hidden = true;
            window.tree.node.setEnabled(false);
            window.popup_tree.node.setEnabled(false);
            window.anim_tree.node.setEnabled(false);
        }
    }

    const wlr_output = output.wlr_output orelse return error.OutputUnavailable;
    var layer_surfaces = server.layer_shell.surfaces.iterator();
    while (layer_surfaces.next()) |layer_surface| {
        if (layer_surface.wlr_layer_surface.output != wlr_output) continue;
        try overview.hidden_layer_surfaces.append(util.gpa, .{
            .ref = layer_surface.ref,
            .tree_enabled = layer_surface.scene_layer_surface.tree.node.enabled,
            .popup_enabled = layer_surface.popup_tree.node.enabled,
        });
        if (layer_surface.wlr_layer_surface.current.layer != .background) {
            layer_surface.scene_layer_surface.tree.node.setEnabled(false);
        }
        layer_surface.popup_tree.node.setEnabled(false);
    }
}

fn restoreOutputScene(overview: *Overview) void {
    for (overview.hidden_windows.items) |hidden| {
        const window = hidden.ref.get() orelse continue;
        window.overview_hidden = hidden.overview_hidden;
        window.tree.node.setEnabled(hidden.tree_enabled);
        window.popup_tree.node.setEnabled(hidden.popup_enabled);
        window.anim_tree.node.setEnabled(hidden.animation_enabled);
    }
    overview.hidden_windows.clearRetainingCapacity();

    for (overview.hidden_layer_surfaces.items) |hidden| {
        const layer_surface = hidden.ref.get() orelse continue;
        layer_surface.scene_layer_surface.tree.node.setEnabled(hidden.tree_enabled);
        layer_surface.popup_tree.node.setEnabled(hidden.popup_enabled);
    }
    overview.hidden_layer_surfaces.clearRetainingCapacity();
}

pub fn step(overview: *Overview, output: *Output, dt_s: f64) bool {
    if (comptime !fx.anim_enabled) return false;
    if (!overview.animatingOn(output.policyId()) or dt_s <= 0) return false;
    const t = 1.0 - @exp(-animation_rate * dt_s);
    overview.progress += (1.0 - overview.progress) * t;
    if (1.0 - overview.progress < 0.002) overview.progress = 1;

    for (overview.entries.items) |*entry| entry.update(overview.progress);
    if (overview.backdrop) |backdrop| {
        const color: [4]f32 = .{ 0, 0, 0, @floatCast(backdrop_opacity * @as(f32, @floatCast(overview.progress))) };
        backdrop.setColor(&color);
    }
    return true;
}

pub fn activeOn(overview: *const Overview, output_id: u64) bool {
    return overview.output_id == output_id and overview.entries.items.len > 0;
}

pub fn animatingOn(overview: *const Overview, output_id: u64) bool {
    if (comptime !fx.anim_enabled) return false;
    return overview.activeOn(output_id) and overview.progress < 1;
}

pub fn active(overview: *const Overview) bool {
    return overview.output_id != null and overview.entries.items.len > 0;
}

pub fn nodeLabel(
    overview: *const Overview,
    node: *wlr.SceneNode,
    buffer: *[512]u8,
) ?[:0]const u8 {
    if (node == &overview.tree.node) return "workspace overview";
    if (overview.backdrop) |backdrop| {
        if (node == &backdrop.node) return "overview backdrop";
    }
    for (overview.entries.items) |entry| {
        if (node == &entry.tree.node) {
            return std.fmt.bufPrintZ(buffer, "overview card: {}", .{entry.handle}) catch
                "overview card";
        }
        for (entry.buffers.items) |record| {
            if (node == &record.buffer.node) return "overview thumbnail buffer";
        }
        inline for (.{ "left", "right", "top", "bottom" }) |name| {
            if (node == &@field(entry.borders, name).node) {
                return "overview selection border: " ++ name;
            }
        }
    }
    return null;
}

fn containsEntry(entries: []const Entry, handle: layout.Handle) bool {
    for (entries) |entry| if (entry.handle == handle) return true;
    return false;
}

fn interpolateRect(start: layout.Rect, target: layout.Rect, progress: f64) layout.Rect {
    return .{
        .x = interpolate(start.x, target.x, progress),
        .y = interpolate(start.y, target.y, progress),
        .width = @max(1, interpolate(start.width, target.width, progress)),
        .height = @max(1, interpolate(start.height, target.height, progress)),
    };
}

fn interpolate(start: i32, target: i32, progress: f64) i32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(start)) +
        @as(f64, @floatFromInt(target - start)) * progress));
}

fn intersection(a: layout.Rect, b: layout.Rect) ?layout.Rect {
    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    const right = @min(a.right(), b.right());
    const bottom = @min(a.bottom(), b.bottom());
    if (right <= x or bottom <= y) return null;
    return .{ .x = x, .y = y, .width = right - x, .height = bottom - y };
}

fn transformSwapsAxes(transform: wl.Output.Transform) bool {
    return switch (transform) {
        .@"90", .@"270", .flipped_90, .flipped_270 => true,
        else => false,
    };
}

fn inverseTransform(transform: wl.Output.Transform) wl.Output.Transform {
    return switch (transform) {
        .@"90" => .@"270",
        .@"270" => .@"90",
        else => transform,
    };
}
