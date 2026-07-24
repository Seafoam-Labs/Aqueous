// SPDX-FileCopyrightText: © 2026 The Aqueous Developers
// SPDX-License-Identifier: GPL-3.0-only

const EffectMetadata = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;
const SlotMap = @import("slotmap").SlotMap;
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

pub const CornerRadii = struct {
    top_left: u31 = 0,
    top_right: u31 = 0,
    bottom_right: u31 = 0,
    bottom_left: u31 = 0,

    pub fn uniform(radius: u31) CornerRadii {
        return .{
            .top_left = radius,
            .top_right = radius,
            .bottom_right = radius,
            .bottom_left = radius,
        };
    }
};

pub const RoundedClip = struct {
    area: wlr.Box,
    radii: CornerRadii,
};

pub const BufferData = struct {
    radii: CornerRadii = .{},
    generation: u64 = 1,
};

pub const RectData = struct {
    radii: CornerRadii = .{},
    clipped_region: ?RoundedClip = null,
    generation: u64 = 1,
};

pub const BlurConfig = struct {
    radius: c_int = 0,
    passes: c_int = 0,
    generation: u64 = 1,
};

pub const WindowBlurData = struct {
    box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    radius: u31 = 0,
    enabled: bool = false,
    generation: u64 = 1,
};

pub const OutputBlurCacheData = struct {
    box: wlr.Box,
    enabled: bool = true,
    invalidation_generation: u64 = 1,
    config_generation: u64,
};

const WindowBlurMap = SlotMap(*WindowBlurRecord);
const OutputBlurCacheMap = SlotMap(*OutputBlurCacheRecord);

pub const WindowBlurHandle = struct {
    key: WindowBlurMap.Key,
};

pub const OutputBlurCacheHandle = struct {
    key: OutputBlurCacheMap.Key,
};

pub const LiveCounts = struct {
    buffers: usize,
    rects: usize,
    window_blurs: usize,
    output_blur_caches: usize,

    pub fn total(counts: LiveCounts) usize {
        return counts.buffers +
            counts.rects +
            counts.window_blurs +
            counts.output_blur_caches;
    }
};

const BufferRecord = struct {
    owner: *EffectMetadata,
    object: *wlr.SceneBuffer,
    data: BufferData,
    destroy: wl.Listener(void) = .init(handleDestroy),

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const record: *BufferRecord = @fieldParentPtr("destroy", listener);
        record.owner.removeBufferRecord(record);
    }
};

const RectRecord = struct {
    owner: *EffectMetadata,
    object: *wlr.SceneRect,
    data: RectData,
    destroy: wl.Listener(void) = .init(handleDestroy),

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const record: *RectRecord = @fieldParentPtr("destroy", listener);
        record.owner.removeRectRecord(record);
    }
};

const WindowBlurRecord = struct {
    owner: *EffectMetadata,
    tree: *wlr.SceneTree,
    handle: WindowBlurHandle,
    data: WindowBlurData = .{},
    destroy: wl.Listener(void) = .init(handleDestroy),

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const record: *WindowBlurRecord = @fieldParentPtr("destroy", listener);
        record.owner.destroyWindowBlur(record.handle);
    }
};

const OutputBlurCacheRecord = struct {
    owner: *EffectMetadata,
    tree: *wlr.SceneTree,
    handle: OutputBlurCacheHandle,
    data: OutputBlurCacheData,
    destroy: wl.Listener(void) = .init(handleDestroy),

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const record: *OutputBlurCacheRecord = @fieldParentPtr("destroy", listener);
        record.owner.destroyOutputBlurCache(record.handle);
    }
};

allocator: Allocator,
buffers: AutoHashMapUnmanaged(*wlr.SceneBuffer, *BufferRecord) = .empty,
rects: AutoHashMapUnmanaged(*wlr.SceneRect, *RectRecord) = .empty,
window_blurs: WindowBlurMap = .empty,
output_blur_caches: OutputBlurCacheMap = .empty,
blur_config: BlurConfig = .{},

pub fn init(allocator: Allocator) EffectMetadata {
    return .{ .allocator = allocator };
}

pub fn deinit(metadata: *EffectMetadata) void {
    var buffer_it = metadata.buffers.valueIterator();
    while (buffer_it.next()) |record_ptr| {
        const record = record_ptr.*;
        record.destroy.link.remove();
        metadata.allocator.destroy(record);
    }
    metadata.buffers.deinit(metadata.allocator);

    var rect_it = metadata.rects.valueIterator();
    while (rect_it.next()) |record_ptr| {
        const record = record_ptr.*;
        record.destroy.link.remove();
        metadata.allocator.destroy(record);
    }
    metadata.rects.deinit(metadata.allocator);

    var window_it = metadata.window_blurs.iterator();
    while (window_it.next()) |record| {
        record.destroy.link.remove();
        metadata.allocator.destroy(record);
    }
    metadata.window_blurs.deinit(metadata.allocator);

    var cache_it = metadata.output_blur_caches.iterator();
    while (cache_it.next()) |record| {
        record.destroy.link.remove();
        metadata.allocator.destroy(record);
    }
    metadata.output_blur_caches.deinit(metadata.allocator);
}

pub fn liveCounts(metadata: *const EffectMetadata) LiveCounts {
    return .{
        .buffers = metadata.buffers.count(),
        .rects = metadata.rects.count(),
        .window_blurs = metadata.window_blurs.count,
        .output_blur_caches = metadata.output_blur_caches.count,
    };
}

pub fn bufferData(metadata: *EffectMetadata, buffer: *wlr.SceneBuffer) ?BufferData {
    const record = metadata.buffers.get(buffer) orelse return null;
    return record.data;
}

pub fn setBufferRadius(
    metadata: *EffectMetadata,
    buffer: *wlr.SceneBuffer,
    radius: u31,
) error{OutOfMemory}!void {
    if (metadata.buffers.get(buffer)) |record| {
        const radii = CornerRadii.uniform(radius);
        if (std.meta.eql(record.data.radii, radii)) return;
        record.data.radii = radii;
        record.data.generation = nextGeneration(record.data.generation);
        if (radius == 0) metadata.removeBufferRecord(record);
        return;
    }
    if (radius == 0) return;

    const record = try metadata.allocator.create(BufferRecord);
    errdefer metadata.allocator.destroy(record);
    record.* = .{
        .owner = metadata,
        .object = buffer,
        .data = .{ .radii = .uniform(radius) },
    };
    try metadata.buffers.put(metadata.allocator, buffer, record);
    buffer.node.events.destroy.add(&record.destroy);
}

pub fn copyBufferData(
    metadata: *EffectMetadata,
    dst: *wlr.SceneBuffer,
    src: *wlr.SceneBuffer,
) error{OutOfMemory}!void {
    if (dst == src) return;
    const src_data = metadata.bufferData(src);
    if (metadata.buffers.get(dst)) |record| metadata.removeBufferRecord(record);
    if (src_data) |data| {
        const record = try metadata.allocator.create(BufferRecord);
        errdefer metadata.allocator.destroy(record);
        record.* = .{
            .owner = metadata,
            .object = dst,
            .data = data,
        };
        try metadata.buffers.put(metadata.allocator, dst, record);
        dst.node.events.destroy.add(&record.destroy);
    }
}

fn removeBufferRecord(metadata: *EffectMetadata, record: *BufferRecord) void {
    if (metadata.buffers.get(record.object) != record) return;
    _ = metadata.buffers.remove(record.object);
    record.destroy.link.remove();
    metadata.allocator.destroy(record);
}

pub fn rectData(metadata: *EffectMetadata, rect: *wlr.SceneRect) ?RectData {
    const record = metadata.rects.get(rect) orelse return null;
    return record.data;
}

pub fn setRectRadius(
    metadata: *EffectMetadata,
    rect: *wlr.SceneRect,
    radius: u31,
) error{OutOfMemory}!void {
    if (metadata.rects.get(rect) == null and radius == 0) return;
    const record = try metadata.getOrCreateRect(rect);
    const radii = CornerRadii.uniform(radius);
    if (std.meta.eql(record.data.radii, radii)) return;
    record.data.radii = radii;
    record.data.generation = nextGeneration(record.data.generation);
    if (radius == 0 and record.data.clipped_region == null) {
        metadata.removeRectRecord(record);
    }
}

pub fn setRectClippedRegion(
    metadata: *EffectMetadata,
    rect: *wlr.SceneRect,
    area: wlr.Box,
    radii: CornerRadii,
) error{OutOfMemory}!void {
    const record = try metadata.getOrCreateRect(rect);
    const clipped_region: RoundedClip = .{ .area = area, .radii = radii };
    if (record.data.clipped_region) |current| {
        if (std.meta.eql(current, clipped_region)) return;
    }
    record.data.clipped_region = clipped_region;
    record.data.generation = nextGeneration(record.data.generation);
}

fn getOrCreateRect(
    metadata: *EffectMetadata,
    rect: *wlr.SceneRect,
) error{OutOfMemory}!*RectRecord {
    if (metadata.rects.get(rect)) |record| return record;

    const record = try metadata.allocator.create(RectRecord);
    errdefer metadata.allocator.destroy(record);
    record.* = .{
        .owner = metadata,
        .object = rect,
        .data = .{},
    };
    try metadata.rects.put(metadata.allocator, rect, record);
    rect.node.events.destroy.add(&record.destroy);
    return record;
}

fn removeRectRecord(metadata: *EffectMetadata, record: *RectRecord) void {
    if (metadata.rects.get(record.object) != record) return;
    _ = metadata.rects.remove(record.object);
    record.destroy.link.remove();
    metadata.allocator.destroy(record);
}

pub fn setBlurConfig(metadata: *EffectMetadata, radius: c_int, passes: c_int) bool {
    if (metadata.blur_config.radius == radius and metadata.blur_config.passes == passes) {
        return false;
    }
    metadata.blur_config.radius = radius;
    metadata.blur_config.passes = passes;
    metadata.blur_config.generation = nextGeneration(metadata.blur_config.generation);
    return true;
}

pub fn blurConfig(metadata: *const EffectMetadata) BlurConfig {
    return metadata.blur_config;
}

pub fn createWindowBlur(
    metadata: *EffectMetadata,
    tree: *wlr.SceneTree,
) error{OutOfMemory}!WindowBlurHandle {
    const record = try metadata.allocator.create(WindowBlurRecord);
    errdefer metadata.allocator.destroy(record);
    record.* = .{
        .owner = metadata,
        .tree = tree,
        .handle = undefined,
    };
    const key = try metadata.window_blurs.put(metadata.allocator, record);
    record.handle = .{ .key = key };
    tree.node.events.destroy.add(&record.destroy);
    return record.handle;
}

pub fn configureWindowBlur(
    metadata: *EffectMetadata,
    handle: WindowBlurHandle,
    box: wlr.Box,
    radius: u31,
    enabled: bool,
) bool {
    const record = metadata.window_blurs.get(handle.key) orelse return false;
    if (std.meta.eql(record.data.box, box) and
        record.data.radius == radius and
        record.data.enabled == enabled)
    {
        return true;
    }
    record.data.box = box;
    record.data.radius = radius;
    record.data.enabled = enabled;
    record.data.generation = nextGeneration(record.data.generation);
    return true;
}

pub fn windowBlurData(
    metadata: *EffectMetadata,
    handle: WindowBlurHandle,
) ?WindowBlurData {
    const record = metadata.window_blurs.get(handle.key) orelse return null;
    return record.data;
}

pub fn destroyWindowBlur(metadata: *EffectMetadata, handle: WindowBlurHandle) void {
    const record = metadata.window_blurs.get(handle.key) orelse return;
    metadata.window_blurs.remove(handle.key);
    record.destroy.link.remove();
    metadata.allocator.destroy(record);
}

pub fn createOutputBlurCache(
    metadata: *EffectMetadata,
    tree: *wlr.SceneTree,
    width: c_int,
    height: c_int,
) error{OutOfMemory}!OutputBlurCacheHandle {
    const record = try metadata.allocator.create(OutputBlurCacheRecord);
    errdefer metadata.allocator.destroy(record);
    record.* = .{
        .owner = metadata,
        .tree = tree,
        .handle = undefined,
        .data = .{
            .box = .{ .x = 0, .y = 0, .width = width, .height = height },
            .config_generation = metadata.blur_config.generation,
        },
    };
    const key = try metadata.output_blur_caches.put(metadata.allocator, record);
    record.handle = .{ .key = key };
    tree.node.events.destroy.add(&record.destroy);
    return record.handle;
}

pub fn configureOutputBlurCache(
    metadata: *EffectMetadata,
    handle: OutputBlurCacheHandle,
    box: wlr.Box,
    enabled: bool,
    dirty: bool,
) bool {
    const record = metadata.output_blur_caches.get(handle.key) orelse return false;
    const geometry_changed = !std.meta.eql(record.data.box, box);
    const config_changed =
        record.data.config_generation != metadata.blur_config.generation;
    record.data.box = box;
    record.data.enabled = enabled;
    record.data.config_generation = metadata.blur_config.generation;
    if (dirty or geometry_changed or config_changed) {
        record.data.invalidation_generation =
            nextGeneration(record.data.invalidation_generation);
    }
    return true;
}

pub fn markOutputBlurCacheDirty(
    metadata: *EffectMetadata,
    handle: OutputBlurCacheHandle,
) bool {
    const record = metadata.output_blur_caches.get(handle.key) orelse return false;
    record.data.invalidation_generation =
        nextGeneration(record.data.invalidation_generation);
    return true;
}

pub fn setOutputBlurCacheEnabled(
    metadata: *EffectMetadata,
    handle: OutputBlurCacheHandle,
    enabled: bool,
) bool {
    const record = metadata.output_blur_caches.get(handle.key) orelse return false;
    record.data.enabled = enabled;
    return true;
}

pub fn outputBlurCacheData(
    metadata: *EffectMetadata,
    handle: OutputBlurCacheHandle,
) ?OutputBlurCacheData {
    const record = metadata.output_blur_caches.get(handle.key) orelse return null;
    return record.data;
}

pub fn destroyOutputBlurCache(
    metadata: *EffectMetadata,
    handle: OutputBlurCacheHandle,
) void {
    const record = metadata.output_blur_caches.get(handle.key) orelse return;
    metadata.output_blur_caches.remove(handle.key);
    record.destroy.link.remove();
    metadata.allocator.destroy(record);
}

fn nextGeneration(current: u64) u64 {
    const next = current +% 1;
    return if (next == 0) 1 else next;
}

fn initNodeDestroySignal(node: *wlr.SceneNode) void {
    node.events.destroy.init();
}

test "scene metadata follows node lifetime and pointer reuse" {
    var metadata = EffectMetadata.init(std.testing.allocator);
    defer metadata.deinit();

    var buffer: wlr.SceneBuffer = undefined;
    initNodeDestroySignal(&buffer.node);
    try metadata.setBufferRadius(&buffer, 14);
    try std.testing.expectEqual(@as(u31, 14), metadata.bufferData(&buffer).?.radii.top_left);
    try std.testing.expectEqual(@as(usize, 1), metadata.liveCounts().buffers);

    buffer.node.events.destroy.emit();
    try std.testing.expectEqual(@as(?BufferData, null), metadata.bufferData(&buffer));
    try std.testing.expectEqual(@as(usize, 0), metadata.liveCounts().buffers);

    initNodeDestroySignal(&buffer.node);
    try metadata.setBufferRadius(&buffer, 7);
    try std.testing.expectEqual(@as(u31, 7), metadata.bufferData(&buffer).?.radii.top_left);
    buffer.node.events.destroy.emit();

    var rect: wlr.SceneRect = undefined;
    initNodeDestroySignal(&rect.node);
    try metadata.setRectRadius(&rect, 9);
    try metadata.setRectClippedRegion(
        &rect,
        .{ .x = 2, .y = 3, .width = 40, .height = 50 },
        .uniform(4),
    );
    try std.testing.expectEqual(@as(u31, 9), metadata.rectData(&rect).?.radii.top_right);
    rect.node.events.destroy.emit();
    try std.testing.expectEqual(@as(?RectData, null), metadata.rectData(&rect));
}

test "buffer metadata is copied into scene snapshots" {
    var metadata = EffectMetadata.init(std.testing.allocator);
    defer metadata.deinit();

    var src: wlr.SceneBuffer = undefined;
    var dst: wlr.SceneBuffer = undefined;
    initNodeDestroySignal(&src.node);
    initNodeDestroySignal(&dst.node);

    try metadata.setBufferRadius(&src, 15);
    try metadata.copyBufferData(&dst, &src);
    try std.testing.expectEqualDeep(metadata.bufferData(&src), metadata.bufferData(&dst));

    src.node.events.destroy.emit();
    try std.testing.expect(metadata.bufferData(&dst) != null);
    dst.node.events.destroy.emit();
    try std.testing.expectEqual(@as(usize, 0), metadata.liveCounts().total());
}

test "blur handles reject stale generations and track invalidation" {
    var metadata = EffectMetadata.init(std.testing.allocator);
    defer metadata.deinit();

    var tree: wlr.SceneTree = undefined;
    initNodeDestroySignal(&tree.node);

    const old_window = try metadata.createWindowBlur(&tree);
    try std.testing.expect(metadata.configureWindowBlur(
        old_window,
        .{ .x = 1, .y = 2, .width = 300, .height = 200 },
        15,
        true,
    ));
    metadata.destroyWindowBlur(old_window);
    try std.testing.expect(!metadata.configureWindowBlur(
        old_window,
        .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        1,
        true,
    ));

    const new_window = try metadata.createWindowBlur(&tree);
    try std.testing.expect(old_window.key.index == new_window.key.index);
    try std.testing.expect(old_window.key.generation != new_window.key.generation);

    const cache = try metadata.createOutputBlurCache(&tree, 1920, 1080);
    const first = metadata.outputBlurCacheData(cache).?;
    try std.testing.expect(!metadata.setBlurConfig(0, 0));
    try std.testing.expect(metadata.setBlurConfig(12, 2));
    try std.testing.expect(metadata.configureOutputBlurCache(
        cache,
        .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        true,
        false,
    ));
    const configured = metadata.outputBlurCacheData(cache).?;
    try std.testing.expect(configured.invalidation_generation != first.invalidation_generation);
    try std.testing.expectEqual(metadata.blurConfig().generation, configured.config_generation);

    try std.testing.expect(metadata.markOutputBlurCacheDirty(cache));
    const dirtied = metadata.outputBlurCacheData(cache).?;
    try std.testing.expect(dirtied.invalidation_generation != configured.invalidation_generation);

    tree.node.events.destroy.emit();
    try std.testing.expectEqual(@as(usize, 0), metadata.liveCounts().total());
    try std.testing.expect(!metadata.markOutputBlurCacheDirty(cache));
}

test "deinit releases records whose owners are still alive" {
    var metadata = EffectMetadata.init(std.testing.allocator);

    var buffer: wlr.SceneBuffer = undefined;
    var rect: wlr.SceneRect = undefined;
    var tree: wlr.SceneTree = undefined;
    initNodeDestroySignal(&buffer.node);
    initNodeDestroySignal(&rect.node);
    initNodeDestroySignal(&tree.node);

    try metadata.setBufferRadius(&buffer, 5);
    try metadata.setRectRadius(&rect, 6);
    _ = try metadata.createWindowBlur(&tree);
    _ = try metadata.createOutputBlurCache(&tree, 800, 600);
    try std.testing.expectEqual(@as(usize, 4), metadata.liveCounts().total());

    metadata.deinit();
    buffer.node.events.destroy.emit();
    rect.node.events.destroy.emit();
    tree.node.events.destroy.emit();
}
