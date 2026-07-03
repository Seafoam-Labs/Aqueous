// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const Server = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const posix = std.posix;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const wp = wayland.server.wp;

const util = @import("util.zig");
const fx = @import("fx.zig");

const IdleInhibitManager = @import("IdleInhibitManager.zig");
const InputManager = @import("InputManager.zig");
const LockManager = @import("LockManager.zig");
const Output = @import("Output.zig");
const OutputManager = @import("OutputManager.zig");
const Scene = @import("Scene.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Seat = @import("Seat.zig");
const TabletTool = @import("TabletTool.zig");
const Window = @import("Window.zig");
const WindowManager = @import("WindowManager.zig");
const WorkspaceManager = @import("WorkspaceManager.zig");
const XkbBindings = @import("XkbBindings.zig");
const LayerShell = @import("LayerShell.zig");
const LibinputConfig = @import("LibinputConfig.zig");
const XkbConfig = @import("XkbConfig.zig");
const XdgDecoration = @import("XdgDecoration.zig");
const XdgToplevel = @import("XdgToplevel.zig");
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");
const XwaylandWindow = @import("XwaylandWindow.zig");

const log = std.log;
const linux = std.os.linux;

/// Final, ready-to-use `KEY=VALUE` selector strings for the chosen render
/// device. Each is NUL-terminated so it can be appended verbatim to the child
/// `envp` in main.zig, exactly like `WAYLAND_DISPLAY`. A field is null when it
/// does not apply (e.g. `dri_prime` is never set for the NVIDIA proprietary
/// driver, which DRI_PRIME cannot select). All-null means "do not pin".
pub const GpuPin = struct {
    vk_select: ?[:0]u8 = null,
    gl_vendor: ?[:0]u8 = null,
    dri_prime: ?[:0]u8 = null,
    nv_offload: ?[:0]u8 = null,
};

wl_server: *wl.Server,

sigint_source: *wl.EventSource,
sigterm_source: *wl.EventSource,

fixes: *wlr.Fixes,

backend: *wlr.Backend,
session: ?*wlr.Session,

renderer: *wlr.Renderer,
allocator: *wlr.Allocator,
gpu_reset_recover: ?*wl.EventSource = null,

/// GPU selector environment variables resolved from the renderer's DRM device.
/// Injected into the spawned init child (see main.zig) so every downstream
/// client pins to the same GPU the compositor renders on, avoiding the
/// dual-GPU GObject toggle-ref crash. Empty on single-GPU systems.
gpu_pin: GpuPin = .{},

security_context_manager: *wlr.SecurityContextManagerV1,

shm: *wlr.Shm,
linux_dmabuf: ?*wlr.LinuxDmabufV1 = null,
linux_drm_syncobj_manager: ?*wlr.LinuxDrmSyncobjManagerV1 = null,
single_pixel_buffer_manager: *wlr.SinglePixelBufferManagerV1,
alpha_modifier: *wlr.AlphaModifierV1,

color_manager: ?*wlr.ColorManagerV1 = null,
color_representation_manager: *wlr.ColorRepresentationManagerV1,

viewporter: *wlr.Viewporter,
fractional_scale_manager: *wlr.FractionalScaleManagerV1,
compositor: *wlr.Compositor,
subcompositor: *wlr.Subcompositor,
cursor_shape_manager: *wlr.CursorShapeManagerV1,

xdg_shell: *wlr.XdgShell,
xdg_decoration_manager: *wlr.XdgDecorationManagerV1,
xdg_activation: *wlr.XdgActivationV1,
xdg_foreign_registry: *wlr.XdgForeignRegistry,
xdg_foreign_v2: *wlr.XdgForeignV2,

data_device_manager: *wlr.DataDeviceManager,
primary_selection_manager: *wlr.PrimarySelectionDeviceManagerV1,
data_control_manager: *wlr.ExtDataControlManagerV1,
wlr_data_control_manager: *wlr.DataControlManagerV1,

export_dmabuf_manager: *wlr.ExportDmabufManagerV1,
screencopy_manager: *wlr.ScreencopyManagerV1,

image_copy_capture_manager: *wlr.ExtImageCopyCaptureManagerV1,
output_image_capture_source_manager: *wlr.ExtOutputImageCaptureSourceManagerV1,

wlr_foreign_toplevel_manager: *wlr.ForeignToplevelManagerV1,
foreign_toplevel_list: *wlr.ExtForeignToplevelListV1,
toplevel_capture_source_manager: *wlr.ExtForeignToplevelImageCaptureSourceManagerV1,

tearing_control_manager: *wlr.TearingControlManagerV1,

scene: Scene,
input_manager: InputManager,
libinput_config: LibinputConfig,
xkb_config: XkbConfig,
om: OutputManager,
idle_inhibit_manager: IdleInhibitManager,
lock_manager: LockManager,
wm: WindowManager,
workspace_manager: WorkspaceManager,
xkb_bindings: XkbBindings,
layer_shell: LayerShell,

xwayland: if (build_options.xwayland) ?*wlr.Xwayland else void = if (build_options.xwayland) null,
new_xsurface: if (build_options.xwayland) wl.Listener(*wlr.XwaylandSurface) else void =
    if (build_options.xwayland) .init(handleNewXwaylandSurface),

renderer_lost: wl.Listener(void) = .init(handleRendererLost),
new_xdg_toplevel: wl.Listener(*wlr.XdgToplevel) = .init(handleNewXdgToplevel),
new_toplevel_decoration: wl.Listener(*wlr.XdgToplevelDecorationV1) = .init(handleNewToplevelDecoration),
request_activate: wl.Listener(*wlr.XdgActivationV1.event.RequestActivate) = .init(handleRequestActivate),
request_set_cursor_shape: wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape) = .init(handleRequestSetCursorShape),
toplevel_capture_request: wl.Listener(*wlr.ExtForeignToplevelImageCaptureSourceManagerV1.Request) = .init(handleToplevelCaptureRequest),

/// Count render-capable GPUs by probing the conventional render-node range.
/// Multi-GPU is the only condition that triggers the toggle-ref crash, so a
/// result <= 1 means we leave the environment untouched.
fn countRenderNodes() usize {
    var count: usize = 0;
    var n: u32 = 128;
    while (n < 192) : (n += 1) {
        var buf: [64]u8 = undefined;
        const p = std.fmt.bufPrintZ(&buf, "/dev/dri/renderD{d}", .{n}) catch continue;
        if (linux.errno(linux.access(p, linux.F_OK)) == .SUCCESS) count += 1;
    }
    return count;
}

/// Read a small sysfs attribute, returning a trimmed slice into `out`.
fn readSysValue(path_z: [:0]const u8, out: []u8) ?[]const u8 {
    const rc = linux.open(path_z, .{}, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const rn = linux.read(fd, out.ptr, out.len);
    if (linux.errno(rn) != .SUCCESS) return null;
    if (rn == 0) return null;
    return mem.trim(u8, out[0..rn], " \t\r\n");
}

/// readlink(2) wrapper returning a slice into `out`, or null on error.
fn readLinkZ(path_z: [:0]const u8, out: []u8) ?[]const u8 {
    const rc = linux.readlink(path_z, out.ptr, out.len);
    if (linux.errno(rc) != .SUCCESS) return null;
    return out[0..rc];
}

/// sysfs stores PCI ids as "0x10de"; strip the prefix for the selector format.
fn stripHexPrefix(s: []const u8) []const u8 {
    return if (mem.startsWith(u8, s, "0x")) s[2..] else s;
}

fn isBootVga(device_dir: []const u8) bool {
    var pbuf: [256]u8 = undefined;
    var vbuf: [16]u8 = undefined;
    const p = std.fmt.bufPrintZ(&pbuf, "{s}/boot_vga", .{device_dir}) catch return false;
    const v = readSysValue(p, &vbuf) orelse return false;
    return mem.eql(u8, v, "1");
}

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn resolveScanoutCard(out: []u8) ?[]const u8 {
    if (countRenderNodes() <= 1) return null;

    const open_rc = linux.open("/sys/class/drm", .{ .DIRECTORY = true }, 0);
    if (linux.errno(open_rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(open_rc);
    defer _ = linux.close(fd);

    var best: ?u32 = null;
    var best_boot_vga = true;

    var dbuf: [4096]u8 align(8) = undefined;
    while (true) {
        const nread = linux.getdents64(fd, &dbuf, dbuf.len);
        if (linux.errno(nread) != .SUCCESS) return null;
        if (nread == 0) break;

        var off: usize = 0;
        while (off < nread) {
            const ent: *linux.dirent64 = @ptrCast(@alignCast(&dbuf[off]));
            const name_ptr: [*:0]const u8 = @ptrCast(&dbuf[off + @offsetOf(linux.dirent64, "name")]);
            const name = mem.span(name_ptr);
            off += ent.reclen;

            const dash = mem.indexOfScalar(u8, name, '-') orelse continue;
            const card = name[0..dash];
            if (!mem.startsWith(u8, card, "card")) continue;
            const num = std.fmt.parseInt(u32, card[4..], 10) catch continue;

            var sbuf: [256]u8 = undefined;
            const spath = std.fmt.bufPrintZ(&sbuf, "/sys/class/drm/{s}/status", .{name}) catch continue;
            var vbuf: [32]u8 = undefined;
            const status = readSysValue(spath, &vbuf) orelse continue;
            if (!mem.eql(u8, status, "connected")) continue;

            var ddbuf: [256]u8 = undefined;
            const device_dir = std.fmt.bufPrintZ(&ddbuf, "/sys/class/drm/{s}/device", .{card}) catch continue;
            var lbuf: [256]u8 = undefined;
            if (readLinkZ(device_dir, &lbuf) == null) continue;

            const bv = isBootVga(device_dir);
            const take = if (best) |b| blk: {
                if (best_boot_vga and !bv) break :blk true;
                if (!best_boot_vga and bv) break :blk false;
                break :blk num < b;
            } else true;
            if (take) {
                best = num;
                best_boot_vga = bv;
            }
        }
    }

    const num = best orelse return null;
    return std.fmt.bufPrint(out, "/dev/dri/card{d}", .{num}) catch null;
}

/// Resolve the DRM device behind `drm_fd` and build the per-vendor client
/// selector env vars. Returns an empty `GpuPin` on single-GPU systems or on any
/// failure/ambiguity (fail-safe: never emit a possibly-wrong pin).
fn resolveGpuPin(drm_fd: c_int) GpuPin {
    if (drm_fd < 0) return .{};
    if (countRenderNodes() <= 1) return .{};

    // Resolve which DRM node the renderer fd points at via /proc/self/fd,
    // avoiding the need for fstat (removed from std.posix in this Zig version).
    var fdlink_buf: [64]u8 = undefined;
    const fdlink = std.fmt.bufPrintZ(&fdlink_buf, "/proc/self/fd/{d}", .{drm_fd}) catch return .{};
    var node_buf: [256]u8 = undefined;
    const node_path = readLinkZ(fdlink, &node_buf) orelse return .{};
    const node_name = std.fs.path.basename(node_path); // cardN or renderDN
    if (node_name.len == 0) return .{};

    var dir_buf: [128]u8 = undefined;
    const device_dir = std.fmt.bufPrintZ(
        &dir_buf,
        "/sys/class/drm/{s}/device",
        .{node_name},
    ) catch return .{};

    // vendor:device (e.g. 10de:2b85), the cross-vendor Vulkan selector value.
    var path_buf: [192]u8 = undefined;
    var vendor_buf: [16]u8 = undefined;
    var device_buf: [16]u8 = undefined;

    const vendor_path = std.fmt.bufPrintZ(&path_buf, "{s}/vendor", .{device_dir}) catch return .{};
    const vendor = stripHexPrefix(readSysValue(vendor_path, &vendor_buf) orelse return .{});

    const device_path = std.fmt.bufPrintZ(&path_buf, "{s}/device", .{device_dir}) catch return .{};
    const device = stripHexPrefix(readSysValue(device_path, &device_buf) orelse return .{});

    // PCI bus tag (e.g. pci-0000_01_00_0) from the device symlink target.
    var link_buf: [256]u8 = undefined;
    const link = readLinkZ(device_dir, &link_buf) orelse return .{};
    const pci = std.fs.path.basename(link); // 0000:01:00.0
    var tag_buf: [64]u8 = undefined;
    if (pci.len == 0 or pci.len > tag_buf.len) return .{};
    for (pci, 0..) |ch, idx| {
        tag_buf[idx] = if (ch == ':' or ch == '.') '_' else ch;
    }
    const pci_tag = tag_buf[0..pci.len];

    // Driver name (e.g. nvidia, amdgpu) from the device's driver symlink.
    var driver_link_buf: [256]u8 = undefined;
    var driver_path_buf: [192]u8 = undefined;
    const driver_path = std.fmt.bufPrintZ(&driver_path_buf, "{s}/driver", .{device_dir}) catch return .{};
    const driver: []const u8 = readLinkZ(driver_path, &driver_link_buf) orelse "";
    const driver_name = std.fs.path.basename(driver);

    var pin: GpuPin = .{};

    // MESA_VK_DEVICE_SELECT works above all ICDs (incl. the NVIDIA proprietary
    // one), so it is the right cross-vendor Vulkan lever on every system.
    pin.vk_select = std.fmt.allocPrintSentinel(
        util.gpa,
        "MESA_VK_DEVICE_SELECT={s}:{s}",
        .{ vendor, device },
        0,
    ) catch null;

    if (mem.eql(u8, driver_name, "nvidia") or mem.eql(u8, driver_name, "nvidia-drm")) {
        // DRI_PRIME is Mesa-only and cannot select the proprietary NVIDIA GPU.
        pin.gl_vendor = std.fmt.allocPrintSentinel(
            util.gpa,
            "__GLX_VENDOR_LIBRARY_NAME=nvidia",
            .{},
            0,
        ) catch null;
        if (!isBootVga(device_dir)) {
            pin.nv_offload = std.fmt.allocPrintSentinel(
                util.gpa,
                "__NV_PRIME_RENDER_OFFLOAD=1",
                .{},
                0,
            ) catch null;
        }
    } else {
        // Mesa drivers (amdgpu/radeonsi/i915/xe/nouveau): GL via DRI_PRIME.
        pin.dri_prime = std.fmt.allocPrintSentinel(
            util.gpa,
            "DRI_PRIME=pci-{s}",
            .{pci_tag},
            0,
        ) catch null;
    }

    log.info("gpu-pin: device={s}:{s} pci={s} driver={s} -> vk={?s} gl={?s} prime={?s} offload={?s}", .{
        vendor,        device,        pci_tag,       driver_name,
        pin.vk_select, pin.gl_vendor, pin.dri_prime, pin.nv_offload,
    });

    return pin;
}

pub fn init(server: *Server, runtime_xwayland: bool) !void {
    // We intentionally don't try to prevent memory leaks on error in this function
    // since river will exit during initialization anyway if there is an error.
    // This keeps the code simpler and more readable.

    const wl_server = try wl.Server.create();
    const loop = wl_server.getEventLoop();

    var scanout_buf: [64]u8 = undefined;
    if (resolveScanoutCard(&scanout_buf)) |card| {
        if (std.c.getenv("WLR_DRM_DEVICES") == null) {
            const z = std.fmt.allocPrintSentinel(util.gpa, "{s}", .{card}, 0) catch null;
            if (z) |zz| {
                _ = setenv("WLR_DRM_DEVICES", zz.ptr, 1);
                log.info("gpu-pin: scanout pinned to {s} (connected monitor)", .{card});
            }
        } else {
            log.info("gpu-pin: WLR_DRM_DEVICES already set by env, leaving as-is", .{});
        }
    }

    var session: ?*wlr.Session = undefined;
    const backend = try wlr.Backend.autocreate(loop, &session);
    const renderer = try fx.createRenderer(backend);

    const compositor = try wlr.Compositor.create(wl_server, 6, renderer);

    const xdg_foreign_registry = try wlr.XdgForeignRegistry.create(wl_server);

    server.* = .{
        .wl_server = wl_server,
        .sigint_source = try loop.addSignal(*wl.Server, @intFromEnum(posix.SIG.INT), terminate, wl_server),
        .sigterm_source = try loop.addSignal(*wl.Server, @intFromEnum(posix.SIG.TERM), terminate, wl_server),

        .fixes = try wlr.Fixes.create(wl_server, 1),

        .backend = backend,
        .session = session,
        .renderer = renderer,
        .allocator = try wlr.Allocator.autocreate(backend, renderer),

        .security_context_manager = try wlr.SecurityContextManagerV1.create(wl_server),

        .shm = try wlr.Shm.createWithRenderer(wl_server, 2, renderer),
        .single_pixel_buffer_manager = try wlr.SinglePixelBufferManagerV1.create(wl_server),
        .alpha_modifier = try wlr.AlphaModifierV1.create(wl_server),

        .color_representation_manager = try wlr.ColorRepresentationManagerV1.createWithRenderer(wl_server, 1, renderer),

        .viewporter = try wlr.Viewporter.create(wl_server),
        .fractional_scale_manager = try wlr.FractionalScaleManagerV1.create(wl_server, 1),
        .compositor = compositor,
        .subcompositor = try wlr.Subcompositor.create(wl_server),
        .cursor_shape_manager = try wlr.CursorShapeManagerV1.create(server.wl_server, 2),

        .xdg_shell = try wlr.XdgShell.create(wl_server, 5),
        .xdg_decoration_manager = try wlr.XdgDecorationManagerV1.create(wl_server),
        .xdg_activation = try wlr.XdgActivationV1.create(wl_server),
        .xdg_foreign_registry = xdg_foreign_registry,
        .xdg_foreign_v2 = try wlr.XdgForeignV2.create(wl_server, xdg_foreign_registry),

        .data_device_manager = try wlr.DataDeviceManager.create(wl_server),
        .primary_selection_manager = try wlr.PrimarySelectionDeviceManagerV1.create(wl_server),
        .data_control_manager = try wlr.ExtDataControlManagerV1.create(wl_server, 1),
        .wlr_data_control_manager = try wlr.DataControlManagerV1.create(wl_server),

        .export_dmabuf_manager = try wlr.ExportDmabufManagerV1.create(wl_server),
        .screencopy_manager = try wlr.ScreencopyManagerV1.create(wl_server),

        .image_copy_capture_manager = try wlr.ExtImageCopyCaptureManagerV1.create(wl_server, 1),
        .output_image_capture_source_manager = try wlr.ExtOutputImageCaptureSourceManagerV1.create(wl_server, 1),

        .wlr_foreign_toplevel_manager = try wlr.ForeignToplevelManagerV1.create(wl_server),
        .foreign_toplevel_list = try wlr.ExtForeignToplevelListV1.create(wl_server, 1),
        .toplevel_capture_source_manager = try wlr.ExtForeignToplevelImageCaptureSourceManagerV1.create(wl_server, 1),

        .tearing_control_manager = try wlr.TearingControlManagerV1.create(wl_server, 1),

        .scene = undefined,
        .om = undefined,
        .input_manager = undefined,
        .libinput_config = undefined,
        .xkb_config = undefined,
        .idle_inhibit_manager = undefined,
        .lock_manager = undefined,
        .wm = undefined,
        .workspace_manager = undefined,
        .xkb_bindings = undefined,
        .layer_shell = undefined,
    };

    if (renderer.getTextureFormats(@intFromEnum(wlr.BufferCap.dmabuf)) != null) {
        server.linux_dmabuf = try wlr.LinuxDmabufV1.createWithRenderer(wl_server, 5, renderer);
    }
    if (renderer.features.timeline and backend.features.timeline) {
        const drm_fd = renderer.getDrmFd();
        if (drm_fd >= 0) {
            server.linux_drm_syncobj_manager = wlr.LinuxDrmSyncobjManagerV1.create(wl_server, 1, drm_fd);
        }
    }

    // Resolve the GPU the renderer landed on and build the client selector env
    // vars. This is the single source of truth for "which GPU"; clients are
    // pinned to the exact device behind the renderer's DRM fd so they can never
    // straddle two GPU stacks. No-op on single-GPU systems.
    server.gpu_pin = resolveGpuPin(renderer.getDrmFd());

    if (renderer.features.input_color_transform) {
        const render_intents: []const wp.ColorManagerV1.RenderIntent = &.{.perceptual};
        const transfer_functions = renderer.transferFunctionList();
        defer std.c.free(transfer_functions.ptr);
        const primaries = renderer.primariesList();
        defer std.c.free(primaries.ptr);
        server.color_manager = try wlr.ColorManagerV1.create(wl_server, 2, .{
            .features = .{
                .parametric = true,
                .set_mastering_display_primaries = true,
            },
            .render_intents = render_intents,
            .transfer_functions = transfer_functions,
            .primaries = primaries,
        });
    }

    if (build_options.xwayland and runtime_xwayland) {
        server.xwayland = try wlr.Xwayland.create(wl_server, compositor, false);
        server.xwayland.?.events.new_surface.add(&server.new_xsurface);
    }

    try server.wm.init();
    try server.workspace_manager.init();
    try server.xkb_bindings.init();
    try server.layer_shell.init();
    try server.scene.init();
    try server.om.init();
    try server.input_manager.init();
    try server.libinput_config.init();
    try server.xkb_config.init();
    try server.idle_inhibit_manager.init();
    try server.lock_manager.init();

    server.renderer.events.lost.add(&server.renderer_lost);
    server.xdg_shell.events.new_toplevel.add(&server.new_xdg_toplevel);
    server.xdg_decoration_manager.events.new_toplevel_decoration.add(&server.new_toplevel_decoration);
    server.xdg_activation.events.request_activate.add(&server.request_activate);
    server.cursor_shape_manager.events.request_set_shape.add(&server.request_set_cursor_shape);
    server.toplevel_capture_source_manager.events.new_request.add(&server.toplevel_capture_request);

    wl_server.setGlobalFilter(*Server, globalFilter, server);
}

/// Free allocated memory and clean up. Note: order is important here
pub fn deinit(server: *Server) void {
    server.sigint_source.remove();
    server.sigterm_source.remove();

    server.renderer_lost.link.remove();
    server.new_xdg_toplevel.link.remove();
    server.new_toplevel_decoration.link.remove();
    server.request_activate.link.remove();
    server.request_set_cursor_shape.link.remove();
    server.toplevel_capture_request.link.remove();

    server.input_manager.new_input.link.remove();
    server.om.new_output.link.remove();

    if (build_options.xwayland) {
        if (server.xwayland) |xwayland| {
            server.new_xsurface.link.remove();
            xwayland.destroy();
        }
    }

    server.wl_server.destroyClients();

    server.backend.destroy();

    // The scene graph needs to be destroyed after the backend but before the renderer
    // Output destruction requires the scene graph to still be around while the scene
    // graph may require the renderer to still be around to destroy textures it seems.
    server.scene.wlr_scene.tree.node.destroy();

    server.renderer.destroy();
    server.allocator.destroy();

    server.om.deinit();
    server.input_manager.deinit();
    server.idle_inhibit_manager.deinit();
    server.lock_manager.deinit();
    server.layer_shell.deinit();

    server.wl_server.destroy();
}

fn globalFilter(client: *const wl.Client, global: *const wl.Global, server: *Server) bool {
    // Only expose the xwalyand_shell_v1 global to the Xwayland process.
    if (build_options.xwayland) {
        if (server.xwayland) |xwayland| {
            if (global == xwayland.shell_v1.global) {
                if (xwayland.server) |xwayland_server| {
                    return client == xwayland_server.client;
                }
                return false;
            }
        }
    }

    // User-configurable allow/block lists are TODO
    const allowed = server.allowlist(global);
    const blocked = server.blocklist(global);
    assert(allowed != blocked);

    if (server.security_context_manager.lookupClient(client) != null) {
        return allowed;
    } else {
        return true;
    }
}

/// Returns true if the global is allowlisted for security contexts
fn allowlist(server: *Server, global: *const wl.Global) bool {
    if (server.linux_dmabuf) |linux_dmabuf| {
        if (global == linux_dmabuf.global) return true;
    }
    if (server.linux_drm_syncobj_manager) |linux_drm_syncobj_manager| {
        if (global == linux_drm_syncobj_manager.global) return true;
    }
    if (server.color_manager) |color_manager| {
        if (global == color_manager.global) return true;
    }

    // We must use the getInterface() approach for dynamically created globals
    // such as wl_output and wl_seat since the wl_global_create() function will
    // advertise the global to clients and invoke this filter before returning
    // the new global pointer.
    if ((mem.orderZ(u8, global.getInterface().name, "wl_output") == .eq) or
        (mem.orderZ(u8, global.getInterface().name, "wl_seat") == .eq))
    {
        return true;
    }

    // For other globals I like the current pointer comparison approach as it
    // should catch river accidentally exposing multiple copies of e.g. wl_shm
    // with an assertion failure.
    return global == server.fixes.global or
        global == server.shm.global or
        global == server.single_pixel_buffer_manager.global or
        global == server.alpha_modifier.global or
        global == server.color_representation_manager.global or
        global == server.viewporter.global or
        global == server.fractional_scale_manager.global or
        global == server.compositor.global or
        global == server.subcompositor.global or
        global == server.cursor_shape_manager.global or
        global == server.xdg_shell.global or
        global == server.xdg_decoration_manager.global or
        global == server.xdg_activation.global or
        global == server.xdg_foreign_v2.exporter.global or
        global == server.xdg_foreign_v2.importer.global or
        global == server.data_device_manager.global or
        global == server.primary_selection_manager.global or
        global == server.tearing_control_manager.global or
        global == server.om.presentation.global or
        global == server.om.xdg_output_manager.global or
        global == server.input_manager.relative_pointer_manager.global or
        global == server.input_manager.pointer_constraints.global or
        global == server.input_manager.text_input_manager.global or
        global == server.input_manager.tablet_manager.global or
        global == server.input_manager.pointer_gestures.global or
        global == server.idle_inhibit_manager.wlr_manager.global or
        global == server.workspace_manager.global or
        global == server.screencopy_manager.global;
}

/// Returns true if the global is blocked for security contexts
fn blocklist(server: *Server, global: *const wl.Global) bool {
    return global == server.security_context_manager.global or
        global == server.wm.global or
        global == server.layer_shell.global or
        global == server.layer_shell.wlr_shell.global or
        global == server.xkb_bindings.global or
        global == server.image_copy_capture_manager.global or
        global == server.output_image_capture_source_manager.global or
        global == server.wlr_foreign_toplevel_manager.global or
        global == server.foreign_toplevel_list.global or
        global == server.toplevel_capture_source_manager.global or
        global == server.export_dmabuf_manager.global or
        global == server.data_control_manager.global or
        global == server.wlr_data_control_manager.global or
        global == server.om.wlr_output_manager.global or
        global == server.om.power_manager.global or
        global == server.om.gamma_control_manager.global or
        global == server.libinput_config.global or
        global == server.xkb_config.global or
        global == server.input_manager.global or
        global == server.input_manager.idle_notifier.global or
        global == server.input_manager.virtual_pointer_manager.global or
        global == server.input_manager.virtual_keyboard_manager.global or
        global == server.input_manager.input_method_manager.global or
        global == server.lock_manager.wlr_manager.global;
}

/// Handle SIGINT and SIGTERM by gracefully stopping the server
fn terminate(_: c_int, wl_server: *wl.Server) c_int {
    wl_server.terminate();
    return 0;
}

fn handleRendererLost(listener: *wl.Listener(void)) void {
    const server: *Server = @fieldParentPtr("renderer_lost", listener);
    if (server.gpu_reset_recover != null) {
        log.info("ignoring GPU reset event, recovery already scheduled", .{});
        return;
    }
    log.info("received GPU reset event, scheduling recovery", .{});
    // There's a design wart in this wlroots API: calling wlr_renderer_destroy()
    // from inside this listener for the renderer lost event causes the assertion
    // that all listener lists are empty in wlr_renderer_destroy() to fail. This
    // happens even if river has already called server.renderer_lost.link.remove()
    // since wlroots uses wl_signal_emit_mutable(), which is implemented by adding
    // temporary links to the list during iteration.
    // Using an idle callback is the most straightforward way to work around this
    // design wart.
    const event_loop = server.wl_server.getEventLoop();
    server.gpu_reset_recover = event_loop.addIdle(*Server, gpuResetRecoverIdle, server) catch |err| switch (err) {
        error.OutOfMemory => {
            log.err("out of memory", .{});
            return;
        },
    };
}

fn gpuResetRecoverIdle(server: *Server) void {
    server.gpu_reset_recover = null;
    // There's not much that can be done if creating a new renderer or allocator fails.
    // With luck there might be another GPU reset after which we try again and succeed.
    server.gpuResetRecover() catch |err| switch (err) {
        error.RendererCreateFailed => log.err("failed to create new renderer after GPU reset", .{}),
        error.AllocatorCreateFailed => log.err("failed to create new allocator after GPU reset", .{}),
    };
}

fn gpuResetRecover(server: *Server) !void {
    log.info("recovering from GPU reset", .{});
    const new_renderer = try fx.createRenderer(server.backend);
    errdefer new_renderer.destroy();

    const new_allocator = try wlr.Allocator.autocreate(server.backend, new_renderer);
    errdefer comptime unreachable; // no failure allowed after this point

    server.renderer_lost.link.remove();
    new_renderer.events.lost.add(&server.renderer_lost);

    server.compositor.setRenderer(new_renderer);

    {
        var it = server.om.outputs.iterator(.forward);
        while (it.next()) |output| {
            if (output.wlr_output) |wlr_output| {
                // This should never fail here as failure with this combination of
                // renderer, allocator, and backend should have prevented creating
                // the output in the first place.
                _ = wlr_output.initRender(new_allocator, new_renderer);
            }
        }
    }

    server.renderer.destroy();
    server.renderer = new_renderer;

    server.allocator.destroy();
    server.allocator = new_allocator;

    if (server.linux_dmabuf) |old_dmabuf| {
        if (new_renderer.getTextureFormats(@intFromEnum(wlr.BufferCap.dmabuf)) != null) {
            if (wlr.LinuxDmabufV1.createWithRenderer(server.wl_server, 5, new_renderer)) |new_dmabuf| {
                old_dmabuf.global.destroy();
                server.linux_dmabuf = new_dmabuf;
                server.scene.wlr_scene.setLinuxDmabufV1(new_dmabuf);
                log.info("re-advertised linux-dmabuf feedback after GPU reset", .{});
            } else |err| {
                log.err("failed to re-advertise linux-dmabuf after GPU reset: {s}", .{@errorName(err)});
            }
        }
    }
}

fn handleNewXdgToplevel(_: *wl.Listener(*wlr.XdgToplevel), xdg_toplevel: *wlr.XdgToplevel) void {
    XdgToplevel.create(xdg_toplevel) catch {
        log.err("out of memory", .{});
        xdg_toplevel.resource.postNoMemory();
        return;
    };
}

fn handleNewToplevelDecoration(
    _: *wl.Listener(*wlr.XdgToplevelDecorationV1),
    wlr_decoration: *wlr.XdgToplevelDecorationV1,
) void {
    XdgDecoration.init(wlr_decoration);
}

fn handleNewXwaylandSurface(_: *wl.Listener(*wlr.XwaylandSurface), xsurface: *wlr.XwaylandSurface) void {
    if (xsurface.override_redirect) {
        _ = XwaylandOverrideRedirect.create(xsurface) catch {
            log.err("out of memory", .{});
            return;
        };
    } else {
        _ = XwaylandWindow.create(xsurface) catch {
            log.err("out of memory", .{});
            return;
        };
    }
}

fn handleRequestActivate(
    listener: *wl.Listener(*wlr.XdgActivationV1.event.RequestActivate),
    event: *wlr.XdgActivationV1.event.RequestActivate,
) void {
    const server: *Server = @fieldParentPtr("request_activate", listener);
    const node_data = SceneNodeData.fromSurface(event.surface) orelse return;
    switch (node_data.data) {
        .window => |window| {
            // Focus-stealing prevention for xdg-activation-v1 self-raises (e.g. a chat client
            // raising itself when a message arrives). wlroots leaves the activation token's
            // `seat` null (and its serial invalid) unless the token was minted from a real,
            // recent input event on a seat. Only forward user-driven activations to the wm
            // client as activate_requested; silently drop spontaneous ones so a background app
            // cannot pull keyboard focus. The wm still applies its own workspace/rule policy
            // when it receives activate_requested.
            if (event.token.seat == null) {
                log.info("xdg-activation: dropping spontaneous activate request (focus-stealing prevention)", .{});
                return;
            }
            const window_v1 = window.object orelse return;
            if (window_v1.getVersion() >= 5) {
                window_v1.sendActivateRequested();
                server.wm.dirtyWindowing();
            }
        },
        else => |tag| {
            log.info("ignoring xdg-activation-v1 activate request of {s} surface", .{@tagName(tag)});
        },
    }
}

fn handleRequestSetCursorShape(
    listener: *wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape),
    event: *wlr.CursorShapeManagerV1.event.RequestSetShape,
) void {
    const server: *Server = @fieldParentPtr("request_set_cursor_shape", listener);
    const seat: *Seat = @ptrCast(@alignCast(event.seat_client.seat.data));

    const name = wlr.CursorShapeManagerV1.shapeName(event.shape);

    if (event.tablet_tool) |wp_tool| {
        assert(event.device_type == .tablet_tool);

        const tool = TabletTool.get(event.seat_client.seat, wp_tool.wlr_tool) catch return;
        if (tool.allowSetCursor(event.seat_client, event.serial)) {
            tool.wlr_cursor.setXcursor(seat.cursor.xcursor_manager, name);
        }
    } else {
        assert(event.device_type == .pointer);

        // Only the client with pointer focus is allowed to set the cursor
        const focused_client = event.seat_client.seat.pointer_state.focused_client;
        if (event.seat_client == focused_client) {
            seat.cursor.setImage(.{ .xcursor = name });
        }
        // Except for the window manager client
        if (server.wm.object) |object| {
            if (event.seat_client.client == object.getClient() and
                object.getVersion() >= 4)
            {
                seat.cursor.setWmImage(.{ .xcursor = name });
            }
        }
    }
}

fn handleToplevelCaptureRequest(
    listener: *wl.Listener(*wlr.ExtForeignToplevelImageCaptureSourceManagerV1.Request),
    request: *wlr.ExtForeignToplevelImageCaptureSourceManagerV1.Request,
) void {
    const server: *Server = @fieldParentPtr("toplevel_capture_request", listener);
    const window = @as(?*Window, @ptrCast(@alignCast(request.toplevel_handle.data))) orelse return;

    const capture_source = window.capture_source orelse wlr.ExtImageCaptureSourceV1.createWithSceneNode(
        &window.capture_scene.tree.node,
        server.wl_server.getEventLoop(),
        server.allocator,
        server.renderer,
    ) catch {
        log.err("failed to create ext image capture source", .{});
        return;
    };

    window.capture_source = capture_source;

    _ = request.accept(capture_source);
}
