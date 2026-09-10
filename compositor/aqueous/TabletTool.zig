// SPDX-FileCopyrightText: © 2024 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const TabletTool = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Tablet = @import("Tablet.zig");
const Mapping = @import("TabletMapping.zig");
const policy = @import("tablet");

const log = std.log.scoped(.input);

const Mode = union(enum) {
    passthrough,
    down: struct {
        node: *wlr.SceneNode,
    },
};

wp_tool: *wlr.TabletV2TabletTool,

wlr_cursor: *wlr.Cursor,

mode: Mode = .passthrough,
link: wl.list.Link = undefined,
tablet: ?*Tablet = null,
mapping: Mapping.Mapping = .{},
in_proximity: bool = false,
deferred_mapping: bool = false,
physical_down: bool = false,
wait_release: bool = false,
normalized_x: f64 = 0.5,
normalized_y: f64 = 0.5,
node_destroy: wl.Listener(void) = .init(handleNodeDestroy),

// A wlroots event may notify us of a change on one of these axes but not
// include the value of the other. We must always send both values to the
// client, which means we need to track this state.
tilt_x: f64 = 0,
tilt_y: f64 = 0,

destroy: wl.Listener(*wlr.TabletTool) = .init(handleDestroy),
set_cursor: wl.Listener(*wlr.TabletV2TabletTool.event.SetCursor) = .init(handleSetCursor),

pub fn get(wlr_seat: *wlr.Seat, wlr_tool: *wlr.TabletTool) error{OutOfMemory}!*TabletTool {
    if (@as(?*TabletTool, @ptrCast(@alignCast(wlr_tool.data)))) |tool| {
        return tool;
    } else {
        return TabletTool.create(wlr_seat, wlr_tool);
    }
}

fn create(wlr_seat: *wlr.Seat, wlr_tool: *wlr.TabletTool) error{OutOfMemory}!*TabletTool {
    const tool = try util.gpa.create(TabletTool);
    errdefer util.gpa.destroy(tool);

    const wlr_cursor = try wlr.Cursor.create();
    errdefer wlr_cursor.destroy();

    wlr_cursor.attachOutputLayout(server.om.output_layout);

    const tablet_manager = server.input_manager.tablet_manager;
    tool.* = .{
        .wp_tool = try tablet_manager.createTabletV2TabletTool(wlr_seat, wlr_tool),
        .wlr_cursor = wlr_cursor,
    };

    server.input_manager.tablet_tools.append(tool);
    wlr_tool.data = tool;

    wlr_tool.events.destroy.add(&tool.destroy);
    tool.wp_tool.events.set_cursor.add(&tool.set_cursor);

    return tool;
}

fn handleDestroy(listener: *wl.Listener(*wlr.TabletTool), _: *wlr.TabletTool) void {
    const tool: *TabletTool = @fieldParentPtr("destroy", listener);

    // wlroots registered its tool-destroy listener first and has already freed wp_tool.
    tool.clearMode();
    tool.link.remove();
    tool.wlr_cursor.destroy();

    tool.destroy.link.remove();
    tool.set_cursor.link.remove();

    util.gpa.destroy(tool);
}

pub fn allowSetCursor(tool: *TabletTool, seat_client: *wlr.Seat.Client, serial: u32) bool {
    if (tool.wp_tool.focused_surface == null or
        tool.wp_tool.focused_surface.?.resource.getClient() != seat_client.client)
    {
        log.debug("client tried to set cursor without focus", .{});
        return false;
    }
    if (serial != tool.wp_tool.proximity_serial) {
        log.debug("focused client tried to set cursor with incorrect serial", .{});
        return false;
    }
    return true;
}

fn handleSetCursor(
    listener: *wl.Listener(*wlr.TabletV2TabletTool.event.SetCursor),
    event: *wlr.TabletV2TabletTool.event.SetCursor,
) void {
    const tool: *TabletTool = @fieldParentPtr("set_cursor", listener);

    if (tool.allowSetCursor(event.seat_client, event.serial)) {
        tool.wlr_cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
    }
}

/// Must be called before moving/warping TabletTool.wlr_cursor
/// Must call detach() after attach() is called before returning.
fn attach(tool: *TabletTool, tablet: *Tablet) void {
    tool.wlr_cursor.attachInputDevice(tablet.device.wlr_device);
    tool.wlr_cursor.mapInputToOutput(tablet.device.wlr_device, tablet.device.config.map_to_output);
    tool.wlr_cursor.mapInputToRegion(tablet.device.wlr_device, &tablet.device.config.map_to_rectangle);
}

fn detach(tool: *TabletTool, tablet: *Tablet) void {
    tool.wlr_cursor.detachInputDevice(tablet.device.wlr_device);
}

pub fn axis(tool: *TabletTool, tablet: *Tablet, event: *wlr.Tablet.event.Axis) void {
    tool.syncMapping(tablet);
    if (!tool.in_proximity or tool.mapping.blocked() or tool.wait_release) return;
    tool.attach(tablet);
    defer tool.detach(tablet);

    if (event.updated_axes.x or event.updated_axes.y) {
        // I don't own all these different types of tablet tools to test that this
        // is correct for each, this is best effort from reading code/docs.
        // The same goes for all the different axes events.
        switch (tool.wp_tool.wlr_tool.type) {
            .pen, .eraser, .brush, .pencil, .airbrush, .totem => {
                if (event.updated_axes.x and std.math.isFinite(event.x)) tool.normalized_x = event.x;
                if (event.updated_axes.y and std.math.isFinite(event.y)) tool.normalized_y = event.y;
                tool.position(tablet);
            },
            .lens, .mouse => {
                tool.wlr_cursor.move(tablet.device.wlr_device, event.dx, event.dy);
            },
        }

        switch (tool.mode) {
            .passthrough => {
                tool.passthrough(tablet);
            },
            .down => |data| {
                // Invert the same destination projection used for scene hit testing.
                var lx: c_int = 0;
                var ly: c_int = 0;
                if (data.node.coords(&lx, &ly)) {
                    const projection = @import("scene_surface_projection.zig");
                    const origin = projection.surfaceToDestination(data.node, 0, 0);
                    const basis_x = projection.surfaceToDestination(data.node, 1, 0);
                    const basis_y = projection.surfaceToDestination(data.node, 0, 1);
                    const ax = basis_x.x - origin.x;
                    const ay = basis_x.y - origin.y;
                    const bx = basis_y.x - origin.x;
                    const by = basis_y.y - origin.y;
                    const dx = tool.wlr_cursor.x - @as(f64, @floatFromInt(lx)) - origin.x;
                    const dy = tool.wlr_cursor.y - @as(f64, @floatFromInt(ly)) - origin.y;
                    const det = ax * by - ay * bx;
                    if (std.math.isFinite(det) and @abs(det) > 1e-12) tool.wp_tool.notifyMotion((dx * by - dy * bx) / det, (dy * ax - dx * ay) / det);
                }
            },
        }
    }
    if (event.updated_axes.distance) {
        tool.wp_tool.notifyDistance(event.distance);
    }
    if (event.updated_axes.pressure) {
        tool.wp_tool.notifyPressure(event.pressure);
    }
    if (event.updated_axes.tilt_x or event.updated_axes.tilt_y) {
        if (event.updated_axes.tilt_x) tool.tilt_x = event.tilt_x;
        if (event.updated_axes.tilt_y) tool.tilt_y = event.tilt_y;

        tool.wp_tool.notifyTilt(tool.tilt_x, tool.tilt_y);
    }
    if (event.updated_axes.rotation) {
        tool.wp_tool.notifyRotation(event.rotation);
    }
    if (event.updated_axes.slider) {
        tool.wp_tool.notifySlider(event.slider);
    }
    if (event.updated_axes.wheel) {
        tool.wp_tool.notifyWheel(event.wheel_delta, 0);
    }
}

pub fn proximity(tool: *TabletTool, tablet: *Tablet, event: *wlr.Tablet.event.Proximity) void {
    switch (event.state) {
        .in => {
            tool.syncMapping(tablet);
            tool.in_proximity = true;
            if (!tool.in_proximity or tool.mapping.blocked() or tool.wait_release) return;
            tool.attach(tablet);
            defer tool.detach(tablet);

            if (std.math.isFinite(event.x)) tool.normalized_x = event.x;
            if (std.math.isFinite(event.y)) tool.normalized_y = event.y;
            tool.position(tablet);

            tool.wlr_cursor.setXcursor(tablet.device.seat.cursor.xcursor_manager, "pencil");

            tool.passthrough(tablet);
        },
        .out => {
            tool.cancel();
            tool.in_proximity = false;
            tool.physical_down = false;
            tool.wait_release = false;
            tool.syncMapping(tablet);
        },
    }
}

pub fn tip(tool: *TabletTool, tablet: *Tablet, event: *wlr.Tablet.event.Tip) void {
    tool.physical_down = event.state == .down;
    tool.syncMapping(tablet);
    if (!tool.in_proximity or tool.mapping.blocked()) return;
    if (tool.wait_release) {
        if (event.state == .up) tool.wait_release = false;
        return;
    }
    switch (event.state) {
        .down => {
            // There have been reports of libinput emitting inconsistent down/up events.
            if (tool.wp_tool.is_down) return;

            if (tool.wp_tool.focused_surface == null) tool.passthrough(tablet);
            if (tool.wp_tool.focused_surface == null) return;
            tool.wp_tool.notifyDown();

            if (server.scene.at(tool.wlr_cursor.x, tool.wlr_cursor.y)) |result| {
                if (result.surface != null) {
                    tool.clearMode();
                    result.node.events.destroy.add(&tool.node_destroy);
                    tool.mode = .{
                        .down = .{
                            .node = result.node,
                        },
                    };
                }
            }
        },
        .up => {
            // There have been reports of libinput emitting inconsistent down/up events.
            if (!tool.wp_tool.is_down) return;

            tool.wp_tool.notifyUp();
            tool.maybeExitDown(tablet);
        },
    }
}

pub fn button(tool: *TabletTool, tablet: *Tablet, event: *wlr.Tablet.event.Button) void {
    tool.syncMapping(tablet);
    if (!tool.in_proximity or tool.mapping.blocked() or tool.wait_release) return;
    const pressed = std.mem.indexOfScalar(u32, tool.wp_tool.pressed_buttons[0..tool.wp_tool.num_buttons], event.button) != null;
    if (pressed == (event.state == .pressed)) return;
    tool.wp_tool.notifyButton(event.button, event.state);

    tool.maybeExitDown(tablet);
}

/// Exit down mode if the tool is up and there are no buttons pressed.
fn maybeExitDown(tool: *TabletTool, tablet: *Tablet) void {
    if (tool.mode != .down or tool.wp_tool.is_down or tool.wp_tool.num_buttons > 0) {
        return;
    }

    tool.clearMode();
    tool.passthrough(tablet);
}

/// Send a motion event for the surface under the tablet tool's cursor if any.
/// Send a proximity_in event first if needed.
/// If there is no surface under the cursor or the surface under the cursor
/// does not support the tablet v2 protocol, send a proximity_out event.
fn passthrough(tool: *TabletTool, tablet: *Tablet) void {
    if (!tool.in_proximity or tool.mapping.blocked() or tool.wait_release) return;
    if (server.scene.at(tool.wlr_cursor.x, tool.wlr_cursor.y)) |result| {
        if (result.data != .lock_surface and server.lock_manager.state != .unlocked) {
            tool.cancel();
            return;
        }

        if (result.surface) |surface| {
            tool.wp_tool.notifyProximityIn(tablet.wp_tablet, surface);
            tool.wp_tool.notifyMotion(result.sx, result.sy);
            return;
        }
    } else {
        tool.wlr_cursor.setXcursor(tablet.device.seat.cursor.xcursor_manager, "pencil");
    }

    tool.wp_tool.notifyProximityOut();
}

fn clearMode(tool: *TabletTool) void {
    if (tool.mode == .down) tool.node_destroy.link.remove();
    tool.mode = .passthrough;
}
fn handleNodeDestroy(listener: *wl.Listener(void)) void {
    const tool: *TabletTool = @fieldParentPtr("node_destroy", listener);
    tool.cancel();
}
pub fn cancel(tool: *TabletTool) void {
    tool.clearMode();
    if (tool.wp_tool.is_down) tool.wp_tool.notifyUp();
    while (tool.wp_tool.num_buttons > 0) tool.wp_tool.notifyButton(tool.wp_tool.pressed_buttons[tool.wp_tool.num_buttons - 1], .released);
    tool.wp_tool.notifyProximityOut();
    tool.wlr_cursor.unsetImage();
    tool.wait_release = tool.physical_down;
}
pub fn syncMapping(tool: *TabletTool, tablet: *Tablet) void {
    if (tool.tablet != tablet) {
        if (tool.tablet != null) tool.cancel();
        tool.tablet = tablet;
        tool.in_proximity = false;
    }
    const relative = tool.wp_tool.wlr_tool.type == .mouse or tool.wp_tool.wlr_tool.type == .lens;
    const next = if (relative and tablet.device.tablet_mapping.status != .disabled) Mapping.Mapping{} else tablet.device.tablet_mapping;
    if (std.meta.eql(next, tool.mapping)) {
        tool.deferred_mapping = false;
        return;
    }
    if (next.blocked() or !Mapping.usable(tool.mapping)) {
        tool.cancel();
    } else if (tool.in_proximity) {
        tool.deferred_mapping = true;
        return;
    }
    tool.mapping = next;
    tool.deferred_mapping = false;
}
fn position(tool: *TabletTool, tablet: *Tablet) void {
    if (tool.mapping.status == .resolved) {
        const p = policy.position(tool.mapping.box, tool.mapping.transform, tool.normalized_x, tool.normalized_y);
        tool.wlr_cursor.warpClosest(null, p.x, p.y);
    } else if (tool.mapping.status == .desktop) {
        tool.wlr_cursor.mapInputToOutput(tablet.device.wlr_device, null);
        tool.wlr_cursor.mapInputToRegion(tablet.device.wlr_device, &.{ .x = 0, .y = 0, .width = 0, .height = 0 });
        tool.wlr_cursor.warpAbsolute(tablet.device.wlr_device, tool.normalized_x, tool.normalized_y);
    } else tool.wlr_cursor.warpAbsolute(tablet.device.wlr_device, tool.normalized_x, tool.normalized_y);
}
