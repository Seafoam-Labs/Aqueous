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
/// Final demolition. The host now owns the complete Wayland lifecycle directly, with no
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
    private readonly ILogger<RiverCompositorHost>? _log;

    private NativeCallbackContext? _callbackContext;
    private CancellationToken _lifetimeToken;
    private bool _started;

    /// <summary>
    /// Join timeout applied to <see cref="IEventPump.Stop"/> during shutdown. Long enough to let an
    /// in-flight <c>wl_display_dispatch</c> return after we cancel; short enough that a wedged
    /// libwayland never blocks shutdown indefinitely.
    /// </summary>
    private static readonly TimeSpan PumpJoinTimeout = TimeSpan.FromSeconds(2);

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

        // Flush globals; then a second roundtrip so any events the compositor sends immediately on bind
        // (for an existing window list) are delivered before we return.
        _connection.Roundtrip();
        _connection.Roundtrip();

        if (_bindSiteState.Manager == IntPtr.Zero)
        {
            return Result.Fail(
                "river_window_manager_v1 global was not advertised — is aqueous-compositor running with WM support?");
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
            // Critical ordering: stop the pump first so it is no longer touching wl_display, then dispose the
            // connection.
            _pump.Stop(PumpJoinTimeout);
            _connection.Dispose();

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
            var managerVersion = Math.Min(global.Version, 4u);
            _manageCycleState.ManagerVersion = managerVersion;
            var managerProxy = _registryBinder.Bind(global.Name, WlInterfaces.RiverWindowManager, managerVersion);
            _bindSiteState.Manager = managerProxy;
            if (managerProxy != IntPtr.Zero)
            {
                WaylandInterop.wl_proxy_add_dispatcher(managerProxy, dispatcher, ctxHandle, IntPtr.Zero);
                _bindSiteState.TrackProxyInterface(managerProxy, "river_window_manager_v1");
                _managerRequestSender.Init(managerProxy, _connection.Display);
                RiverLog.Write($"bound river_window_manager_v1 (version {managerVersion})");
            }
        }
        else if (global.Interface == "river_layer_shell_v1")
        {
            var layerShell = _registryBinder.Bind(global.Name, WlInterfaces.RiverLayerShell, 1);
            _bindSiteState.LayerShell = layerShell;
            WaylandInterop.wl_proxy_add_dispatcher(layerShell, dispatcher, ctxHandle, IntPtr.Zero);
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
}
