using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Diagnostics;
using Aqueous.Features.Bindings;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;
using Aqueous.Features.Screencopy;
using Aqueous.Features.Startup;
using Aqueous.Features.State;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// The host now owns the complete Wayland lifecycle directly, with no
/// <c>RiverWindowManagerClient</c> god class in the picture. All collaborators are resolved from
/// DI.
/// </summary>
internal sealed class RiverCompositorHost : IHostedService
{
    private readonly IWaylandConnection _connection;
    private readonly IWindowRegistry _windowRegistry;
    private readonly IOutputRegistry _outputRegistry;
    private readonly ISeatRegistry _seatRegistry;
    private readonly IEventPump _pump;
    private readonly WaylandBindSiteState _bindSiteState;
    private readonly RegistryBinder _registryBinder;
    private readonly IEventDispatcher _eventDispatcher;
    private readonly IScreencopyService _screencopyService;
    private readonly IManagerRequestSender _managerRequestSender;
    private readonly KeyBindingsRegistry _keyBindingsRegistry;
    private readonly ManageCycleState _manageCycleState;
    private readonly StartupExecRunner _startupExec;
    private readonly LibinputConfigApplier _libinputApplier;
    private readonly XkbConfigApplier _xkbApplier;
    private readonly ILogger<RiverCompositorHost>? _log;

    private NativeCallbackContext? _callbackContext;
    private CancellationToken _lifetimeToken;
    private bool _started;

    /// <summary>
    /// <c>wl_registry</c> name advertised for the currently-bound <c>river_window_manager_v1</c>
    /// global, or <c>null</c> if it is not bound. Tracked so <c>wl_registry::global_remove</c> can be
    /// matched against the manager and the cached proxy in <see cref="IManagerRequestSender"/> can be
    /// cleared before the proxy is destroyed (otherwise <c>wl_proxy_marshal_flags</c> dereferences a
    /// freed proxy at offset 0x2c — see the segfault traced from <c>super+shift+arrow</c>).
    /// </summary>
    private uint? _managerGlobalName;

    /// <summary>
    /// Join timeout applied to <see cref="IEventPump.Stop"/> during shutdown. With the pump's wakeup
    /// fd in place the join completes in milliseconds, so this is purely a safety net; it should
    /// never be hit. If it ever is, <see cref="DisposeWayland"/> deliberately SKIPS
    /// <c>wl_display_disconnect</c> rather than free the display under a live pump thread.
    /// </summary>
    private static readonly TimeSpan PumpJoinTimeout = TimeSpan.FromSeconds(5);

    public RiverCompositorHost(
        IWaylandConnection connection,
        IWindowRegistry windowRegistry,
        IOutputRegistry outputRegistry,
        ISeatRegistry seatRegistry,
        IEventPump pump,
        WaylandBindSiteState bindSiteState,
        RegistryBinder registryBinder,
        IEventDispatcher eventDispatcher,
        IScreencopyService screencopyService,
        IManagerRequestSender managerRequestSender,
        KeyBindingsRegistry keyBindingsRegistry,
        ManageCycleState manageCycleState,
        StartupExecRunner startupExec,
        LibinputConfigApplier libinputApplier,
        XkbConfigApplier xkbApplier,
        ILogger<RiverCompositorHost>? log = null)
    {
        _connection = connection ?? throw new ArgumentNullException(nameof(connection));
        _windowRegistry = windowRegistry ?? throw new ArgumentNullException(nameof(windowRegistry));
        _outputRegistry = outputRegistry ?? throw new ArgumentNullException(nameof(outputRegistry));
        _seatRegistry = seatRegistry ?? throw new ArgumentNullException(nameof(seatRegistry));
        _pump = pump ?? throw new ArgumentNullException(nameof(pump));
        _bindSiteState = bindSiteState ?? throw new ArgumentNullException(nameof(bindSiteState));
        _registryBinder = registryBinder ?? throw new ArgumentNullException(nameof(registryBinder));
        _eventDispatcher = eventDispatcher ?? throw new ArgumentNullException(nameof(eventDispatcher));
        _screencopyService = screencopyService ?? throw new ArgumentNullException(nameof(screencopyService));
        _managerRequestSender = managerRequestSender ?? throw new ArgumentNullException(nameof(managerRequestSender));
        _keyBindingsRegistry = keyBindingsRegistry ?? throw new ArgumentNullException(nameof(keyBindingsRegistry));
        _manageCycleState = manageCycleState ?? throw new ArgumentNullException(nameof(manageCycleState));
        _startupExec = startupExec ?? throw new ArgumentNullException(nameof(startupExec));
        _libinputApplier = libinputApplier ?? throw new ArgumentNullException(nameof(libinputApplier));
        _xkbApplier = xkbApplier ?? throw new ArgumentNullException(nameof(xkbApplier));
        _log = log;
    }

    public Task StartAsync(CancellationToken cancellationToken)
    {
        _log?.LogInformation("RiverCompositorHost starting...");

        if (!RiverEnvironmentGuard.IsEnabled())
        {
            throw new InvalidOperationException(RiverEnvironmentGuard.NotEnabledMessage);
        }

        _lifetimeToken = cancellationToken;

        try
        {
            var connected = Connect();
            if (!connected.IsOk)
            {
                _log?.LogError("Connect failed: {Error}", connected.Error);
                try { DisposeWayland(); } catch { /* best-effort */ }
                throw new InvalidOperationException("Connect failed: " + connected.Error);
            }

            _started = true;

            try { _startupExec.OnStartup(); }
            catch (Exception ex) { _log?.LogWarning(ex, "startup exec failed"); }

            StartPump(cancellationToken);
            _log?.LogInformation(
                "RiverCompositorHost started; attached as window manager (v{ManagerVersion}).",
                _manageCycleState.ManagerVersion);
        }
        catch (DllNotFoundException ex)
        {
            _log?.LogError(ex, "libwayland-client could not be loaded");
            throw new InvalidOperationException(
                "libwayland-client could not be loaded: " + ex.Message, ex);
        }

        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        _log?.LogInformation("RiverCompositorHost stopping...");
        try
        {
            if (_started) DisposeWayland();
        }
        catch (Exception ex)
        {
            _log?.LogWarning(ex, "DisposeWayland threw during shutdown");
        }
        finally
        {
            _started = false;
        }
        return Task.CompletedTask;
    }

    // ---------------------------------------------------------------- Lifecycle bodies fully owned
    // by the host. ------------------------------------------------------------------

    internal unsafe Result Connect()
    {
        var connectResult = _connection.Connect();
        if (!connectResult.IsOk)
        {
            RiverLog.Write("wl_display_connect failed: " + connectResult.Error);
            return connectResult;
        }

        WlInterfaces.EnsureBuilt();

        // Allocate a NativeCallbackContext (which performs the actual GCHandle.Alloc internally). Its
        // IntPtr is what we hand to libwayland as the dispatcher implementation pointer.
        var ctx = new NativeCallbackContext(
            new RiverEventDispatcher(_bindSiteState, _eventDispatcher, _screencopyService));
        _callbackContext = ctx;
        _keyBindingsRegistry.SelfHandlePtr = ctx.Handle;

        IntPtr dispatcher = (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)
            &NativeCallbackEntry.Dispatch;

        if (!_registryBinder.Create(_connection.Display, dispatcher, ctx.Handle))
        {
            RiverLog.Write("get_registry failed");
            return Result.Fail("wl_display_get_registry returned null");
        }

        _bindSiteState.TrackProxyInterface(_registryBinder.Handle, "wl_registry");

        _registryBinder.Discovered += HandleRegistryGlobal;
        _registryBinder.Removed += HandleRegistryRemove;

        // Flush globals; then a second roundtrip so any events the compositor sends immediately on bind
        // (for an existing window list) are delivered before we return.
        _connection.Roundtrip();
        _connection.Roundtrip();

        if (_bindSiteState.Manager == IntPtr.Zero)
        {
            return Result.Fail(
                "river_window_manager_v1 global was not advertised — is RiverDelta running with WM support?");
        }

        return Result.Ok;
    }

    internal void StartPump(CancellationToken cancellationToken = default)
    {
        _pump.Start(cancellationToken);
    }

    internal void DisposeWayland()
    {
        // River_window_manager_v1::stop (opcode 0) is intentionally NOT sent here: it is not a
        // destructor. We disconnect; River treats a disconnected WM the same way as a stopped one and
        // cleans up.
        try
        {
            // Critical ordering: stop the pump first so it is no longer touching wl_display, then dispose
            // the connection. The pump's wakeup fd makes Stop return as soon as the thread leaves
            // libwayland; the bool tells us whether it actually exited.
            bool pumpExited = _pump.Stop(PumpJoinTimeout);
            // Clear the cached manager proxy/display in IManagerRequestSender *before* the connection
            // tears the proxies down — any pump-thread send that races past this point becomes a silent
            // no-op instead of a NULL-deref inside libwayland.
            _managerRequestSender.Reset();
            _managerGlobalName = null;
            _bindSiteState.Manager = IntPtr.Zero;

            // Dispose the screencopy client (and the per-frame wl_buffer / zwlr_screencopy_frame_v1
            // proxies it owns) HERE — after the pump has exited but while the display is STILL
            // connected. WlrScreencopyClient.Dispose marshals zwlr_screencopy_manager_v1::destroy and
            // friends via wl_proxy_marshal_flags; if that ran after wl_display_disconnect (the default
            // DI-container disposal order in Program.Main) it would write into freed proxy memory —
            // the `segfault at 2c` traced from WlrScreencopyClient.Dispose. The pump is already gone,
            // so this marshal is single-threaded and safe.
            if (pumpExited)
            {
                _screencopyService.Dispose();
            }

            // wl_display_disconnect MUST NOT run while the pump thread is still inside any wl_display_*
            // call: freeing the display/proxies underneath it is exactly the `segfault at 2c` teardown
            // race. Only disconnect once the pump has provably exited. If the (near-impossible) join
            // timeout was hit, leak the display rather than crash — a leak at process exit is harmless.
            if (pumpExited)
            {
                _connection.Dispose();
            }
            else
            {
                _log?.LogError(
                    "pump thread did not exit within {Timeout}; SKIPPING wl_display_disconnect to avoid use-after-free",
                    PumpJoinTimeout);
            }

            _windowRegistry.Clear();
            _outputRegistry.Clear();
            _seatRegistry.Clear();
        }
        catch
        {
            // Tear-down is best-effort; never let Dispose throw.
        }
        finally
        {
            if (_callbackContext is { } ctx)
            {
                ctx.Dispose();
                _callbackContext = null;
            }
        }
    }

    internal unsafe void HandleRegistryGlobal(RegistryGlobal global)
    {
        var ctx = _callbackContext ?? throw new InvalidOperationException(
            "HandleRegistryGlobal called before NativeCallbackContext was allocated.");
        IntPtr dispatcher = (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)
            &NativeCallbackEntry.Dispatch;
        IntPtr ctxHandle = ctx.Handle;

        if (global.Interface == "river_window_manager_v1" && _bindSiteState.Manager == IntPtr.Zero)
        {
            var managerVersion = Math.Min(global.Version, 8u);
            _manageCycleState.ManagerVersion = managerVersion;
            var managerProxy = _registryBinder.Bind(global.Name, WlInterfaces.RiverWindowManager, managerVersion);
            _bindSiteState.Manager = managerProxy;
            if (managerProxy != IntPtr.Zero)
            {
                WaylandInterop.wl_proxy_add_dispatcher(managerProxy, dispatcher, ctxHandle, IntPtr.Zero);
                _bindSiteState.TrackProxyInterface(managerProxy, "river_window_manager_v1");
                _managerRequestSender.Init(managerProxy, _connection.Display);
                _managerGlobalName = global.Name;
                RiverLog.Write($"bound river_window_manager_v1 (version {managerVersion})");
            }
        }
        else if (global.Interface == "ext_workspace_manager_v1" && _bindSiteState.WorkspaceManager == IntPtr.Zero)
        {
            var wsmProxy = _registryBinder.Bind(global.Name, WlInterfaces.ExtWorkspaceManager, 1);
            _bindSiteState.WorkspaceManager = wsmProxy;
            if (wsmProxy != IntPtr.Zero)
            {
                WaylandInterop.wl_proxy_add_dispatcher(wsmProxy, dispatcher, ctxHandle, IntPtr.Zero);
                _bindSiteState.TrackProxyInterface(wsmProxy, "ext_workspace_manager_v1");
                RiverLog.Write("bound ext_workspace_manager_v1 (version 1)");
            }
        }
        else if (global.Interface == "river_layer_shell_v1")
        {
            // New protocol shape: river_layer_shell_v1 has no events, so no dispatcher is needed.
            // Binding the global is still required — it tells the compositor the WM supports layer
            // shell (an unbound global makes the compositor close layer surfaces). The bound proxy
            // is retained as the factory for get_output/get_seat.
            var layerShell = _registryBinder.Bind(global.Name, WlInterfaces.RiverLayerShell, 1);
            _bindSiteState.LayerShell = layerShell;
            _bindSiteState.TrackProxyInterface(layerShell, "river_layer_shell_v1");
            RiverLog.Write("bound river_layer_shell_v1");
        }
        else if (global.Interface == "river_xkb_bindings_v1")
        {
            uint xkbVersion = Math.Min(global.Version, 2u);
            var xkb = _registryBinder.Bind(global.Name, WlInterfaces.RiverXkbBindings, xkbVersion);
            _bindSiteState.XkbBindings = xkb;
            _bindSiteState.XkbBindingsVersion = xkbVersion;
            _bindSiteState.TrackProxyInterface(xkb, "river_xkb_bindings_v1");
            RiverLog.Write($"bound river_xkb_bindings_v1 (version {xkbVersion})");
        }
        else if (global.Interface == "river_libinput_config_v1" && _bindSiteState.LibinputConfig == IntPtr.Zero)
        {
            // Cap to v2 — that's what compositor/protocol/river-libinput-config-v1.xml advertises.
            uint version = Math.Min(global.Version, 2u);
            var libinput = _registryBinder.Bind(global.Name, WlInterfaces.RiverLibinputConfig, version);
            _bindSiteState.LibinputConfig = libinput;
            if (libinput != IntPtr.Zero)
            {
                WaylandInterop.wl_proxy_add_dispatcher(libinput, dispatcher, ctxHandle, IntPtr.Zero);
                _bindSiteState.TrackProxyInterface(libinput, "river_libinput_config_v1");
                _libinputApplier.OnBound();
                RiverLog.Write($"bound river_libinput_config_v1 (version {version})");
            }
        }
        else if (global.Interface == "river_xkb_config_v1" && _bindSiteState.XkbConfig == IntPtr.Zero)
        {
            // Cap to v2 — that's what compositor/protocol/river-xkb-config-v1.xml advertises.
            uint version = Math.Min(global.Version, 2u);
            var xkbCfg = _registryBinder.Bind(global.Name, WlInterfaces.RiverXkbConfig, version);
            _bindSiteState.XkbConfig = xkbCfg;
            if (xkbCfg != IntPtr.Zero)
            {
                WaylandInterop.wl_proxy_add_dispatcher(xkbCfg, dispatcher, ctxHandle, IntPtr.Zero);
                _bindSiteState.TrackProxyInterface(xkbCfg, "river_xkb_config_v1");
                _xkbApplier.OnBound(xkbCfg, dispatcher, ctxHandle);
                RiverLog.Write($"bound river_xkb_config_v1 (version {version})");
            }
        }
        else if (global.Interface == "wl_shm" && _bindSiteState.WlShm == IntPtr.Zero)
        {
            var wlShm = _registryBinder.Bind(global.Name, WlInterfaces.WlShm, 1);
            _bindSiteState.WlShm = wlShm;
            _bindSiteState.TrackProxyInterface(wlShm, "wl_shm");
            RiverLog.Write("bound wl_shm");
            _screencopyService.ActivateIfReady(
                _bindSiteState,
                _bindSiteState.ScreencopyVersion,
                ctxHandle,
                dispatcher,
                RiverLog.Write);
        }
        else if (global.Interface == "wl_output")
        {
            // Lazy-bind path: only remember the global. Real wl_output proxies are bound on-demand from
            // CaptureOutputAsync and destroyed immediately after capture.
            _bindSiteState.WlOutputGlobals[global.Name] = global;
        }
        else if (global.Interface == "zwlr_screencopy_manager_v1" && _bindSiteState.ScreencopyManager == IntPtr.Zero)
        {
            var version = Math.Min(global.Version, 3u);
            _bindSiteState.ScreencopyVersion = version;
            var sc = _registryBinder.Bind(global.Name, WlInterfaces.ZwlrScreencopyManager, version);
            _bindSiteState.ScreencopyManager = sc;
            _bindSiteState.TrackProxyInterface(sc, "zwlr_screencopy_manager_v1");
            RiverLog.Write($"bound zwlr_screencopy_manager_v1 (version {version})");
            _screencopyService.ActivateIfReady(
                _bindSiteState,
                version,
                ctxHandle,
                dispatcher,
                RiverLog.Write);
        }
    }

    /// <summary>
    /// Counterpart to <see cref="HandleRegistryGlobal"/>: routes <c>wl_registry::global_remove</c>
    /// for the currently-bound <c>river_window_manager_v1</c> global to <see
    /// cref="IManagerRequestSender.Reset"/>. Clearing <see cref="WaylandBindSiteState.Manager"/> and
    /// <see cref="_managerGlobalName"/> also re-arms the <c>Manager == IntPtr.Zero</c> guard in the
    /// bind path so a subsequently re-advertised global rebinds automatically.
    /// </summary>
    internal void HandleRegistryRemove(uint name)
    {
        if (_managerGlobalName is { } bound && bound == name)
        {
            RiverLog.Write("river_window_manager_v1 global removed; unbinding manager request sender");
            _managerRequestSender.Reset();
            _bindSiteState.Manager = IntPtr.Zero;
            _managerGlobalName = null;
        }
    }
}
