// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

const Server = @This();

const build_options = @import("build_options");
const std = @import("std");
const c = @import("c");
const assert = std.debug.assert;
const mem = std.mem;
const posix = std.posix;
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const wp = wayland.server.wp;

extern fn wlr_aqueous_capture_color_manager_v1_create(display: *wl.Server) ?*wl.Global;
// NULL creates an inert source (the standard denied/unavailable-source reply).
extern fn wlr_ext_foreign_toplevel_image_capture_source_manager_v1_request_accept(
    request: *wlr.ExtForeignToplevelImageCaptureSourceManagerV1.Request,
    source: ?*wlr.ExtImageCaptureSourceV1,
) bool;

const util = @import("util.zig");
const output_retry = @import("output_retry.zig");
const RendererSelection = @import("render/RendererSelection.zig");
const color_management = @import("color_management.zig");
const global_filter = @import("global_filter.zig");
const VulkanContext = if (build_options.vulkan_effects) @import("render/VulkanContext.zig") else void;
const EffectMetadata = if (build_options.vulkan_effects) @import("render/EffectMetadata.zig") else void;

const IdleInhibitManager = @import("IdleInhibitManager.zig");
const InputManager = @import("InputManager.zig");
const LockManager = @import("LockManager.zig");
const LegacyServerDecoration = @import("LegacyServerDecoration.zig");
const CommitTimingManager = @import("CommitTimingManager.zig");
const FifoManager = @import("FifoManager.zig");
const XdgToplevelIconManager = @import("XdgToplevelIconManager.zig");
const XdgDialogManager = @import("XdgDialogManager.zig");
const Output = @import("Output.zig");
const OutputManager = @import("OutputManager.zig");
const Overview = @import("Overview.zig");
const Scene = @import("Scene.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Seat = @import("Seat.zig");
const TabletTool = @import("TabletTool.zig");
const Window = @import("Window.zig");
const WindowManager = @import("WindowManager.zig");
const WindowInfoManager = @import("WindowInfoManager.zig");
const WorkspaceManager = @import("WorkspaceManager.zig");
const XkbBindings = @import("XkbBindings.zig");
const LayerShell = @import("LayerShell.zig");
const LibinputConfig = @import("LibinputConfig.zig");
const XkbConfig = @import("XkbConfig.zig");
const XdgDecoration = @import("XdgDecoration.zig");
const XdgToplevel = @import("XdgToplevel.zig");
const XwaylandOverrideRedirect = @import("XwaylandOverrideRedirect.zig");
const XwaylandWindow = @import("XwaylandWindow.zig");
const xwayland_projection = @import("xwayland_projection.zig");
const Aqueous = @import("wm/Aqueous.zig");
const PolicyMode = @import("wm/Mode.zig").Mode;
const ConfigSnapshot = @import("wm/config/loader.zig").Snapshot;

const log = std.log;

pub var termination_requested = false;

pub const GpuPin = @import("GpuPin.zig");

wl_server: *wl.Server,

sigint_source: *wl.EventSource,
sigterm_source: *wl.EventSource,
child_processes: @import("ChildProcesses.zig") = .{},
input_activity: @import("InputActivityManager.zig") = .{},

fixes: *wlr.Fixes,

backend: *wlr.Backend,
session: ?*wlr.Session,

renderer: *wlr.Renderer,
allocator: *wlr.Allocator,
vulkan_context: if (build_options.vulkan_effects) VulkanContext else void,
effect_metadata: if (build_options.vulkan_effects) EffectMetadata else void,
gpu_reset_recover: ?*wl.EventSource = null,
fatal_error: ?anyerror = null,
selection_attempt: usize,
selection_pending: bool = true,
fd_reserve: output_retry.FdReserve = .{},
fd_pressure: output_retry.FdPressure = .{},

background_effect_manager: @import("BackgroundEffectManager.zig") = .{},

/// GPU selector environment variables resolved from the renderer's DRM device.
/// Injected into the spawned init child (see main.zig) so every downstream
/// client pins to the same GPU the compositor renders on, avoiding the
/// dual-GPU GObject toggle-ref crash. Empty on single-GPU systems.
gpu_pin: GpuPin = .{},

/// True when Aqueous selected the libliftoff DRM path before backend creation.
overlay_planes_enabled: bool,

security_context_manager: *wlr.SecurityContextManagerV1,

shm: *wlr.Shm,
linux_dmabuf: ?*wlr.LinuxDmabufV1 = null,
creating_linux_dmabuf_global: bool = false,
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
legacy_server_decoration: LegacyServerDecoration,
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
capture_color_global: *wl.Global,
output_image_capture_source_manager: *wlr.ExtOutputImageCaptureSourceManagerV1,

wlr_foreign_toplevel_manager: *wlr.ForeignToplevelManagerV1,
foreign_toplevel_list: *wlr.ExtForeignToplevelListV1,
toplevel_capture_source_manager: *wlr.ExtForeignToplevelImageCaptureSourceManagerV1,

tearing_control_manager: *wlr.TearingControlManagerV1,

scene: Scene,
overview: Overview,
window_switcher: @import("WindowSwitcher.zig"),
input_manager: InputManager,
libinput_config: LibinputConfig,
xkb_config: XkbConfig,
om: OutputManager,
idle_inhibit_manager: IdleInhibitManager,
lock_manager: LockManager,
drm_lease: @import("DrmLeaseManager.zig") = .{},
wm: WindowManager,
aqueous: Aqueous,
workspace_manager: WorkspaceManager,
window_info_manager: WindowInfoManager,
shell_manager: @import("ShellManager.zig") = .{},
ipc_server: @import("IpcServer.zig") = .{},
shortcuts: @import("ShortcutInhibitManager.zig") = .{},
xkb_bindings: XkbBindings,
layer_shell: LayerShell,

xwayland: if (build_options.xwayland) ?*wlr.Xwayland else void = if (build_options.xwayland) null,
xwayland_enabled: bool,
xwayland_scaling: xwayland_projection.Mode = .legacy,
xwayland_dpi: @import("XwaylandScaling.zig") = .{},
new_xsurface: if (build_options.xwayland) wl.Listener(*wlr.XwaylandSurface) else void =
    if (build_options.xwayland) .init(handleNewXwaylandSurface),

renderer_lost: wl.Listener(void) = .init(handleRendererLost),
new_xdg_toplevel: wl.Listener(*wlr.XdgToplevel) = .init(handleNewXdgToplevel),
new_toplevel_decoration: wl.Listener(*wlr.XdgToplevelDecorationV1) = .init(handleNewToplevelDecoration),
request_activate: wl.Listener(*wlr.XdgActivationV1.event.RequestActivate) = .init(handleRequestActivate),
request_set_cursor_shape: wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape) = .init(handleRequestSetCursorShape),
toplevel_capture_request: wl.Listener(*wlr.ExtForeignToplevelImageCaptureSourceManagerV1.Request) = .init(handleToplevelCaptureRequest),

content_type_manager: *wlr.ContentTypeManagerV1,
fifo: FifoManager,
commit_timing: CommitTimingManager,
xdg_dialog: XdgDialogManager,
system_bell: @import("SystemBellManager.zig") = .{},
xdg_toplevel_drag: *wl.Global,
xdg_icon: XdgToplevelIconManager,
xdg_tag: @import("XdgToplevelTagManager.zig"),

pub fn init(
    server: *Server,
    selection: *RendererSelection,
    runtime_xwayland: bool,
    policy_mode: PolicyMode,
    xwayland_scaling: xwayland_projection.Mode,
    overlay_planes_enabled: bool,
    startup_config: ConfigSnapshot,
) !void {
    // We intentionally don't try to prevent memory leaks on error in this function
    // since river will exit during initialization anyway if there is an error.
    // This keeps the code simpler and more readable.

    const wl_server = try wl.Server.create();
    var selecting = true;
    errdefer if (selecting) wl_server.destroy();
    wl_display_set_default_max_buffer_size(wl_server, 1024 * 1024);
    const loop = wl_server.getEventLoop();

    // wl_event_loop_add_signal() blocks each signal in the calling thread and
    // consumes it through signalfd. Register these before renderer/backend
    // initialization can create driver threads: threads inherit their creator's
    // mask, whereas a thread created first could receive SIGINT/SIGTERM with the
    // default fatal disposition and bypass orderly compositor/Vulkan teardown.
    const sigint_source = try loop.addSignal(
        *wl.Server,
        @intFromEnum(posix.SIG.INT),
        terminate,
        wl_server,
    );
    errdefer sigint_source.remove();
    const sigterm_source = try loop.addSignal(
        *wl.Server,
        @intFromEnum(posix.SIG.TERM),
        terminate,
        wl_server,
    );
    errdefer sigterm_source.remove();

    // Render preference must not constrain KMS discovery. Setting WLR_DRM_DEVICES
    // also disables wlroots' hotplug monitor, so only honor an explicit user list.
    if (std.c.getenv("WLR_DRM_DEVICES")) |devices| {
        log.info("gpu-selection: explicit display devices={s} hotplug=disabled", .{mem.span(devices)});
    }

    var session: ?*wlr.Session = undefined;
    const backend = try wlr.Backend.autocreate(loop, &session);
    const resources = selection.next(backend) catch |err| {
        backend.destroy();
        return err;
    };
    selecting = false;
    const renderer = resources.renderer;

    const compositor = try wlr.Compositor.create(wl_server, 6, renderer);

    const xdg_foreign_registry = try wlr.XdgForeignRegistry.create(wl_server);

    server.* = .{
        .wl_server = wl_server,
        .sigint_source = sigint_source,
        .sigterm_source = sigterm_source,

        .fixes = try wlr.Fixes.create(wl_server, 1),

        .backend = backend,
        .session = session,
        .renderer = renderer,
        .allocator = resources.allocator,
        .vulkan_context = resources.context,
        .selection_attempt = selection.attempt,
        .effect_metadata = if (comptime build_options.vulkan_effects)
            EffectMetadata.init(util.gpa)
        else {},
        .overlay_planes_enabled = overlay_planes_enabled,

        .security_context_manager = try wlr.SecurityContextManagerV1.create(wl_server),

        .shm = try wlr.Shm.createWithRenderer(wl_server, 2, renderer),
        .single_pixel_buffer_manager = try wlr.SinglePixelBufferManagerV1.create(wl_server),
        .alpha_modifier = try wlr.AlphaModifierV1.create(wl_server),

        .color_representation_manager = try wlr.ColorRepresentationManagerV1.createWithRenderer(wl_server, 1, renderer),

        .content_type_manager = try wlr.ContentTypeManagerV1.create(wl_server, 1),
        .fifo = try FifoManager.init(wl_server),
        .commit_timing = try CommitTimingManager.init(wl_server),
        .xdg_dialog = try XdgDialogManager.init(wl_server),
        .xdg_toplevel_drag = try @import("XdgToplevelDragManager.zig").init(wl_server),
        .xdg_icon = try XdgToplevelIconManager.init(wl_server),
        .xdg_tag = try @import("XdgToplevelTagManager.zig").init(wl_server),

        .viewporter = try wlr.Viewporter.create(wl_server),
        .fractional_scale_manager = try wlr.FractionalScaleManagerV1.create(wl_server, 1),
        .compositor = compositor,
        .xwayland_enabled = build_options.xwayland and runtime_xwayland,
        .xwayland_scaling = xwayland_scaling,
        .subcompositor = try wlr.Subcompositor.create(wl_server),
        .cursor_shape_manager = try wlr.CursorShapeManagerV1.create(server.wl_server, 2),

        .xdg_shell = try wlr.XdgShell.create(wl_server, 7),
        .xdg_decoration_manager = try wlr.XdgDecorationManagerV1.create(wl_server),
        .legacy_server_decoration = try LegacyServerDecoration.init(wl_server, startup_config.wm.force_ssd),
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
        .capture_color_global = wlr_aqueous_capture_color_manager_v1_create(wl_server) orelse return error.OutOfMemory,
        .output_image_capture_source_manager = try wlr.ExtOutputImageCaptureSourceManagerV1.create(wl_server, 1),

        .wlr_foreign_toplevel_manager = try wlr.ForeignToplevelManagerV1.create(wl_server),
        .foreign_toplevel_list = try wlr.ExtForeignToplevelListV1.create(wl_server, 1),
        .toplevel_capture_source_manager = try wlr.ExtForeignToplevelImageCaptureSourceManagerV1.create(wl_server, 1),

        .tearing_control_manager = try wlr.TearingControlManagerV1.create(wl_server, 1),

        .scene = undefined,
        .overview = undefined,
        .window_switcher = undefined,
        .om = undefined,
        .input_manager = undefined,
        .libinput_config = undefined,
        .xkb_config = undefined,
        .idle_inhibit_manager = undefined,
        .lock_manager = undefined,
        .wm = undefined,
        .aqueous = undefined,
        .workspace_manager = undefined,
        .window_info_manager = undefined,
        .xkb_bindings = undefined,
        .layer_shell = undefined,
    };

    try server.child_processes.init(util.gpa, wl_server);
    errdefer server.child_processes.deinit();

    if (renderer.getDrmFd() >= 0 and renderer.getTextureFormats(@intFromEnum(wlr.BufferCap.dmabuf)) != null) {
        server.linux_dmabuf = try wlr.LinuxDmabufV1.createWithRenderer(wl_server, 6, renderer);
    }
    if (renderer.features.timeline and backend.features.timeline) {
        const drm_fd = renderer.getDrmFd();
        if (drm_fd >= 0) {
            server.linux_drm_syncobj_manager = wlr.LinuxDrmSyncobjManagerV1.create(wl_server, 1, drm_fd);
        }
    }

    const inherit_gpu = if (std.c.getenv("AQUEOUS_GPU_POLICY")) |value| mem.eql(u8, mem.span(value), "inherit") else false;
    server.gpu_pin = GpuPin.resolve(util.gpa, renderer.getDrmFd(), inherit_gpu);
    if (server.gpu_pin.identity) |id| {
        log.info("gpu-selection: render_node={s} pci={s} device={s}:{s} driver={s} client_policy={s} agreement=unverified", .{
            id.node, id.pci, id.vendor, id.device, id.driver, @tagName(server.gpu_pin.state),
        });
    } else log.warn("gpu-selection: render identity unavailable client_policy={s} agreement=unverified", .{@tagName(server.gpu_pin.state)});
    if (comptime build_options.vulkan_effects) {
        var layers: [64]c.VkLayerProperties = undefined;
        var count: u32 = layers.len;
        const rc = c.vkEnumerateInstanceLayerProperties(&count, &layers);
        var available = false;
        if (rc == c.VK_SUCCESS or rc == c.VK_INCOMPLETE) {
            for (layers[0..@min(count, layers.len)]) |layer| {
                if (mem.eql(u8, mem.sliceTo(&layer.layerName, 0), "VK_LAYER_MESA_device_select")) available = true;
            }
        }
        log.info("gpu-selection: mesa_device_select_available={} activation=unverified enumeration_result={d}", .{ available, rc });
        if (!available and server.gpu_pin.values[0] != null) log.warn("gpu-selection: requested Vulkan restriction cannot be verified; Mesa device-selection layer unavailable", .{});
    }
    if (std.c.getenv("NODEVICE_SELECT") != null) log.warn("gpu-selection: NODEVICE_SELECT is set; Mesa device-selection layer may be disabled", .{});

    if (renderer.features.input_color_transform) {
        const render_intents: []const wp.ColorManagerV1.RenderIntent = &.{.perceptual};
        const transfer_functions = renderer.transferFunctionList();
        defer std.c.free(transfer_functions.ptr);
        const primaries = renderer.primariesList();
        defer std.c.free(primaries.ptr);
        const windows_hdr_features = if (comptime build_options.vulkan_effects)
            color_management.windowsHdrFeatureMask(transfer_functions, primaries)
        else
            0;
        const color_manager_version = if (build_options.vulkan_effects) 3 else 2;
        server.color_manager = try wlr.ColorManagerV1.create(wl_server, color_manager_version, .{
            .features = .{
                .parametric = true,
                .set_mastering_display_primaries = true,
            },
            .render_intents = render_intents,
            .transfer_functions = transfer_functions,
            .primaries = primaries,
        });
        if (comptime build_options.vulkan_effects) {
            color_management.enableWindowsHdr(server.color_manager.?, windows_hdr_features);
        }
    }

    try server.wm.init();
    server.aqueous.init(policy_mode, startup_config);
    try server.workspace_manager.init();
    try server.window_info_manager.init();
    try server.xkb_bindings.init();
    try server.layer_shell.init();
    try server.scene.init();
    try server.overview.init();
    try server.window_switcher.init();
    try server.om.init();
    try server.input_manager.init();
    try server.libinput_config.init();
    try server.xkb_config.init();
    try server.idle_inhibit_manager.init();
    try server.lock_manager.init();
    try server.shell_manager.init();
    try server.input_activity.init();
    try server.shortcuts.init();
    try server.background_effect_manager.init();

    server.renderer.events.lost.add(&server.renderer_lost);
    server.xdg_shell.events.new_toplevel.add(&server.new_xdg_toplevel);
    try server.system_bell.init();
    server.xdg_dialog.listen();
    server.xdg_icon.listen();
    server.xdg_tag.listen();
    server.xdg_decoration_manager.events.new_toplevel_decoration.add(&server.new_toplevel_decoration);
    server.xdg_activation.events.request_activate.add(&server.request_activate);
    server.cursor_shape_manager.events.request_set_shape.add(&server.request_set_cursor_shape);
    server.toplevel_capture_source_manager.events.new_request.add(&server.toplevel_capture_request);

    server.drm_lease.init(wl_server, server.backend, server.session);
    wl_server.setGlobalFilter(*Server, globalFilter, server);
    server.fd_reserve.fill();
}

/// Start Xwayland only after a renderer has passed the initial commit.
pub fn startXwayland(server: *Server) !void {
    if (comptime build_options.xwayland) {
        server.xwayland = try wlr.Xwayland.create(server.wl_server, server.compositor, false);
        server.xwayland.?.events.new_surface.add(&server.new_xsurface);
        const seat = server.input_manager.defaultSeat();
        server.xwayland.?.setSeat(seat.wlr_seat);
        if (seat.cursor.xcursor_manager.getXcursor("default", 1)) |xcursor| {
            const image = xcursor.images[0];
            server.xwayland.?.setCursor(image.getBuffer(), @intCast(image.hotspot_x), @intCast(image.hotspot_y));
        }
        wlr_output_set_client_projection_handler(handleXwaylandOutputProjection, server);
        server.xwayland_dpi.init(server.xwayland.?);
        if (server.xwayland_scaling == .native) {
            log.info("using native-resolution embedded Xwayland scaling", .{});
        }
    }
}

/// Exercise the ordinary output transaction before publishing a client socket.
/// A disconnected system has nothing to probe; hotplug uses per-output fallback.
pub fn startBackend(server: *Server) !void {
    try server.backend.start();
    var since = util.msecTimestamp();
    while (true) {
        if (termination_requested) return error.StartupCancelled;
        if (server.fatal_error) |err| return err;
        if (!server.om.first_modeset or server.om.outputs.length() == 0) {
            server.selection_pending = false;
            return;
        }
        const active = if (server.session) |session| session.active else true;
        if (!active) since = util.msecTimestamp();
        if (active and util.msecTimestamp() -% since >= 10_000) {
            log.err("initial presentation timed out", .{});
            return error.PresentationUnavailable;
        }
        try server.wl_server.getEventLoop().dispatch(50);
    }
}

/// Free allocated memory and clean up. Note: order is important here
pub fn deinit(server: *Server) void {
    server.child_processes.deinit();
    if (comptime build_options.input_activity_testing) @import("InputActivityTest.zig").finish();
    server.input_activity.stop();
    server.drm_lease.stop();
    server.ipc_server.deinit();
    server.sigint_source.remove();
    server.sigterm_source.remove();

    if (server.gpu_reset_recover) |idle| {
        idle.remove();
        server.gpu_reset_recover = null;
    }
    server.renderer_lost.link.remove();
    server.new_xdg_toplevel.link.remove();
    server.system_bell.deinit();
    server.xdg_dialog.deinit();
    server.xdg_icon.deinit();
    server.xdg_tag.deinit();
    server.new_toplevel_decoration.link.remove();
    server.request_activate.link.remove();
    server.request_set_cursor_shape.link.remove();
    server.toplevel_capture_request.link.remove();

    server.input_manager.new_input.link.remove();
    server.om.new_output.link.remove();

    if (build_options.xwayland) {
        server.xwayland_dpi.deinit();
        wlr_output_set_client_projection_handler(null, null);
        if (server.xwayland) |xwayland| {
            server.new_xsurface.link.remove();
            xwayland.destroy();
        }
    }

    server.wl_server.destroyClients();
    server.window_switcher.deinit();
    server.aqueous.deinit();
    server.overview.deinit();

    server.backend.destroy();
    server.drm_lease.deinit();

    // The scene graph needs to be destroyed after the backend but before the renderer
    // Output destruction requires the scene graph to still be around while the scene
    // graph may require the renderer to still be around to destroy textures it seems.
    server.scene.wlr_scene.tree.node.destroy();
    server.background_effect_manager.deinit();

    if (comptime build_options.vulkan_effects) {
        const live = server.effect_metadata.liveCounts();
        if (live.total() != 0) {
            log.warn(
                "cleaning up {d} effect metadata records after scene destruction",
                .{live.total()},
            );
        }
        server.effect_metadata.deinit();
    }
    if (comptime build_options.vulkan_effects) server.vulkan_context.deinit();
    server.renderer.destroy();
    server.allocator.destroy();

    server.om.deinit();
    server.input_manager.deinit();
    server.idle_inhibit_manager.deinit();
    server.lock_manager.deinit();
    server.layer_shell.deinit();

    server.wl_server.destroy();
    server.gpu_pin.deinit(util.gpa);
    _ = server.fd_reserve.release();
}

const WlrOutputClientProjection = extern struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    scale: i32,
};

const OutputProjectionHandler = *const fn (
    output: *wlr.Output,
    client: *wl.Client,
    projection: *WlrOutputClientProjection,
    data: ?*anyopaque,
) callconv(.c) bool;

extern fn wlr_output_set_client_projection_handler(
    handler: ?OutputProjectionHandler,
    data: ?*anyopaque,
) void;

fn handleXwaylandOutputProjection(
    output: *wlr.Output,
    client: *wl.Client,
    projection: *WlrOutputClientProjection,
    data: ?*anyopaque,
) callconv(.c) bool {
    const self: *Server = @ptrCast(@alignCast(data orelse return false));
    const xwayland = if (build_options.xwayland) self.xwayland orelse return false else return false;
    const xwayland_server = xwayland.server orelse return false;
    if (client != xwayland_server.client) return false;

    const projected = self.om.xwaylandProjectionForOutput(output) orelse return false;
    projection.* = .{
        .x = projected.x11.x,
        .y = projected.x11.y,
        .width = projected.x11.width,
        .height = projected.x11.height,
        .scale = if (self.xwayland_scaling == .native) 1 else @intFromFloat(@ceil(output.scale)),
    };
    return true;
}

fn globalFilter(client: *const wl.Client, global: *const wl.Global, server: *Server) bool {
    // The legacy external WM protocol cannot express a move owned by a DnD
    // grab. Let clients use their fallback until that boundary can carry it.
    if (global == server.xdg_toplevel_drag and !server.aqueous.mode.runsInternal()) return false;
    // Only expose Xwayland-private globals to the Xwayland process.
    if (build_options.xwayland) {
        if (server.xwayland) |xwayland| {
            if (global == xwayland.shell_v1.global or
                global == server.input_manager.xwayland_keyboard_grabs.global)
            {
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
    if (global_filter.temporarilyAllowlistedInterface(
        server.creating_linux_dmabuf_global,
        global.getInterface().name,
    )) return true;

    if (server.background_effect_manager.global) |background_global| {
        if (global == background_global) return true;
    }
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
    return global == server.input_activity.global or
        global == server.fixes.global or
        global == server.fifo.global() or
        global == server.commit_timing.global() or
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
        global == server.xdg_dialog.global() or
        global == server.system_bell.global() or
        global == server.xdg_toplevel_drag or
        global == server.xdg_icon.global() or
        global == server.xdg_tag.global() or
        global == server.xdg_decoration_manager.global or
        global == server.legacy_server_decoration.global() or
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
        global == server.input_manager.pointer_warp.global or
        global == server.input_manager.text_input_manager.global or
        global == server.input_manager.tablet_manager.global or
        global == server.input_manager.pointer_gestures.global or
        global == server.idle_inhibit_manager.wlr_manager.global or
        global == server.workspace_manager.global or
        global == server.screencopy_manager.global or global == server.content_type_manager.global or
        (server.shortcuts.manager != null and global == server.shortcuts.manager.?.global);
}

/// Returns true if the global is blocked for security contexts
fn blocklist(server: *Server, global: *const wl.Global) bool {
    return global_filter.dynamicallyBlocklistedInterface(global.getInterface().name) or
        global == server.security_context_manager.global or
        global == server.wm.global or
        global == server.layer_shell.global or
        global == server.layer_shell.wlr_shell.global or
        global == server.xkb_bindings.global or
        global == server.image_copy_capture_manager.global or
        global == server.capture_color_global or
        global == server.output_image_capture_source_manager.global or
        global == server.wlr_foreign_toplevel_manager.global or
        global == server.foreign_toplevel_list.global or
        global == server.window_info_manager.global or
        global == server.shell_manager.global or
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
    termination_requested = true;
    wl_server.terminate();
    return 0;
}

fn canRecoverVulkanRenderer(server: *const Server) bool {
    if (comptime !build_options.vulkan_effects) return false;
    if (server.selection_pending or server.gpu_reset_recover != null) return false;
    return c.wlr_renderer_is_vk(@ptrCast(server.renderer));
}

fn scheduleRendererRecoveryIdle(server: *Server) void {
    const event_loop = server.wl_server.getEventLoop();
    server.gpu_reset_recover = event_loop.addIdle(*Server, gpuResetRecoverIdle, server) catch |err| switch (err) {
        error.OutOfMemory => {
            log.err("out of memory", .{});
            return;
        },
    };
}

pub fn requestRendererRecovery(server: *Server, reason: []const u8) void {
    if (!server.canRecoverVulkanRenderer()) return;
    log.warn("requesting renderer recovery ({s}), scheduling recovery", .{reason});
    server.scheduleRendererRecoveryIdle();
}

pub fn checkFdPressure(server: *Server, now_ms: u64) void {
    if (!server.fd_pressure.pollDue()) return;
    if (!server.canRecoverVulkanRenderer()) return;
    const soft_limit = output_retry.queryNofileSoftLimit() orelse return;
    const threshold = output_retry.FdPressure.highWaterThreshold(soft_limit) orelse return;
    const open_fds = output_retry.countOpenFdsBounded(soft_limit, threshold) orelse return;
    if (server.fd_pressure.shouldTriggerRecovery(open_fds, soft_limit, now_ms)) {
        log.warn(
            "open_fds>={d} reached high-water threshold {d} (soft_limit={d}), scheduling proactive GPU renderer refresh",
            .{ open_fds, threshold, soft_limit },
        );
        server.requestRendererRecovery("file descriptor high-water mark");
    }
}

fn handleRendererLost(listener: *wl.Listener(void)) void {
    const server: *Server = @fieldParentPtr("renderer_lost", listener);
    if (server.selection_pending) {
        server.fatal_error = error.PresentationUnavailable;
        server.wl_server.terminate();
        return;
    }
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
    server.scheduleRendererRecoveryIdle();
}

fn gpuResetRecoverIdle(server: *Server) void {
    server.gpu_reset_recover = null;
    server.gpuResetRecover() catch |err| {
        log.err("failed to recover rendering after GPU reset: {s}", .{@errorName(err)});
        server.fatal_error = error.VulkanRecoveryFailed;
        server.wl_server.terminate();
    };
}

fn gpuResetRecover(server: *Server) !void {
    var warming_outputs = server.om.outputs.iterator(.forward);
    while (warming_outputs.next()) |output| {
        if (output.wlr_output) |w| server.om.warming.invalidate(w);
    }
    log.info("recovering from GPU reset", .{});
    const released_fds = server.fd_reserve.release();
    if (released_fds > 0) {
        log.info("released {d} reserved file descriptors for GPU recovery", .{released_fds});
    }
    errdefer server.fd_reserve.fill();
    const resources = try RendererSelection.recover(server.backend, server.renderer);
    const new_renderer = resources.renderer;
    errdefer new_renderer.destroy();

    var new_vulkan_context = resources.context;
    errdefer if (comptime build_options.vulkan_effects) new_vulkan_context.deinit();

    const new_allocator = resources.allocator;
    if ((server.renderer.getDrmFd() >= 0) != (new_renderer.getDrmFd() >= 0) or
        server.renderer.features.timeline != new_renderer.features.timeline)
    {
        // Existing clients may own buffers and sync objects from the old device.
        // End the session until migration of those resources is qualified.
        new_allocator.destroy();
        return error.RendererCapabilitiesChanged;
    }
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
                if (!wlr_output.initRender(new_allocator, new_renderer)) {
                    server.fatal_error = error.PresentationRecoveryFailed;
                    server.wl_server.terminate();
                } else {
                    output.retry.copy_failures = 0;
                    output.retry.scene_build_failures = 0;
                    @import("render/Presentation.zig").configure(wlr_output) catch |err| {
                        log.err("output presentation recovery failed: {s}", .{@errorName(err)});
                        server.fatal_error = error.PresentationRecoveryFailed;
                        server.wl_server.terminate();
                    };
                    if (output.scene_output) |scene_output| scene_output.damage_ring.addWhole();
                    if (!output.retry.pending) wlr_output.scheduleFrame();
                }
                output.invalidateOverlayCapabilities();
            }
        }
    }

    if (comptime build_options.vulkan_effects) {
        var output_it = server.om.outputs.iterator(.forward);
        while (output_it.next()) |output| output.releaseVulkanBlurCache();
        server.vulkan_context.deinit();
    }
    server.renderer.destroy();
    server.renderer = new_renderer;
    if (comptime build_options.vulkan_effects) {
        server.vulkan_context = new_vulkan_context;
        var output_it = server.om.outputs.iterator(.forward);
        while (output_it.next()) |output| output.syncBlur(true);
    }

    server.allocator.destroy();
    server.allocator = new_allocator;
    server.fd_reserve.fill();

    if (server.linux_dmabuf) |old_dmabuf| {
        if (new_renderer.getDrmFd() >= 0 and new_renderer.getTextureFormats(@intFromEnum(wlr.BufferCap.dmabuf)) != null) {
            const new_dmabuf_result = blk: {
                server.creating_linux_dmabuf_global = true;
                defer server.creating_linux_dmabuf_global = false;
                break :blk wlr.LinuxDmabufV1.createWithRenderer(
                    server.wl_server,
                    6,
                    new_renderer,
                );
            };
            if (new_dmabuf_result) |new_dmabuf| {
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
    _ = listener;
    const node_data = SceneNodeData.fromSurface(event.surface) orelse return;
    switch (node_data.data) {
        .window => |window| {
            // wlroots validates supplied serials when committing tokens, but
            // also permits tokens without a seat. Reject those self-raises.
            if (event.token.seat == null) {
                log.info("xdg-activation: dropping spontaneous activate request (focus-stealing prevention)", .{});
                return;
            }
            window.requestActivate();
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
    const window = @as(?*Window, @ptrCast(@alignCast(request.toplevel_handle.data))) orelse {
        _ = wlr_ext_foreign_toplevel_image_capture_source_manager_v1_request_accept(request, null);
        return;
    };
    if (!window.captureAllowed()) {
        _ = wlr_ext_foreign_toplevel_image_capture_source_manager_v1_request_accept(request, null);
        return;
    }

    const capture_source = window.capture_source orelse wlr.ExtImageCaptureSourceV1.createWithSceneNode(
        &window.capture_scene.tree.node,
        server.wl_server.getEventLoop(),
        server.allocator,
        server.renderer,
    ) catch {
        log.err("failed to create ext image capture source", .{});
        _ = wlr_ext_foreign_toplevel_image_capture_source_manager_v1_request_accept(request, null);
        return;
    };

    window.trackCaptureSource(capture_source);

    _ = request.accept(capture_source);
}

extern fn wl_display_set_default_max_buffer_size(
    display: *wl.Server,
    max_buffer_size: usize,
) void;
