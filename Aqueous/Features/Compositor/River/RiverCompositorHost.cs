using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Compositor.River.Registry;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Stage 9 PR 9.11 / PR 9.12 §2.13 Step 7 — <see cref="IHostedService"/>
/// that owns the Wayland connection lifecycle. Performs env-var opt-in
/// via <see cref="RiverEnvironmentGuard"/>, resolves
/// <see cref="RiverWindowManagerClient"/> from DI, then drives Connect /
/// startup exec / pump / Dispose in-place.
///
/// <para>
/// Step 7 lift: the bodies of <c>Connect</c>, <c>StartPump</c>,
/// <c>Dispose</c>, and <c>HandleRegistryGlobal</c> now live as methods
/// on the host (<see cref="Connect"/>, <see cref="StartPump"/>,
/// <see cref="DisposeClient"/>, <see cref="HandleRegistryGlobal"/>).
/// They operate on the still-resident god-class transport fields
/// through fine-grained internal accessors (Manager, LayerShell,
/// XkbBindingsHandle, WlShm, ScreencopyManager, SelfHandle,
/// CallbackContext, WlOutputGlobals, Display, Connection, Pump,
/// BindSiteState, ScreencopyService, ManagerRequestSender,
/// KeyBindingsRegistryRef, RegistryBinder, RegistryGlobalBinder,
/// RiverEventDispatcher). The god class keeps thin forwarders
/// (<see cref="RiverWindowManagerClient.Connect"/>,
/// <see cref="RiverWindowManagerClient.HandleRegistryGlobal"/>,
/// <see cref="RiverWindowManagerClient.StartPump"/>,
/// <see cref="RiverWindowManagerClient.Dispose"/>) that delegate here
/// so <c>RegistryGlobalBinder.Bind</c> and any reflection-based tests
/// keep compiling until the final deletion commit.
/// </para>
/// </summary>
internal sealed class RiverCompositorHost : IHostedService
{
    private readonly IServiceProvider _sp;
    private readonly ILogger<RiverCompositorHost>? _log;
    private RiverWindowManagerClient? _client;
    private CancellationToken _lifetimeToken;

    /// <summary>
    /// Join timeout applied to <see cref="IEventPump.Stop"/> during
    /// shutdown. Long enough to let an in-flight
    /// <c>wl_display_dispatch</c> return after we cancel; short enough
    /// that a wedged libwayland never blocks shutdown indefinitely.
    /// </summary>
    private static readonly TimeSpan PumpJoinTimeout = TimeSpan.FromSeconds(2);

    public RiverCompositorHost(IServiceProvider sp, ILogger<RiverCompositorHost>? log = null)
    {
        _sp = sp ?? throw new ArgumentNullException(nameof(sp));
        _log = log;
    }

    /// <summary>The resolved god-class instance once <see cref="StartAsync"/> has run, else null.</summary>
    internal RiverWindowManagerClient? Client => _client;

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
            _client = (RiverWindowManagerClient)_sp.GetService(typeof(RiverWindowManagerClient))!;
        }
        catch (Exception ex)
        {
            _log?.LogError(ex, "RiverWindowManagerClient construction failed");
            throw;
        }

        try
        {
            var connected = Connect();
            if (!connected.IsOk)
            {
                _log?.LogError("Connect failed: {Error}", connected.Error);
                try { DisposeWayland(); } catch { /* best-effort */ }
                _client = null;
                throw new InvalidOperationException("Connect failed: " + connected.Error);
            }

            try { _client.StartupExec.OnStartup(); }
            catch (Exception ex) { _log?.LogWarning(ex, "startup exec failed"); }

            StartPump(cancellationToken);
            _log?.LogInformation(
                "RiverCompositorHost started; attached as window manager (v{ManagerVersion}).",
                _client.ManagerVersion);
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
            if (_client is not null) DisposeWayland();
        }
        catch (Exception ex)
        {
            _log?.LogWarning(ex, "DisposeClient threw during shutdown");
        }
        finally
        {
            _client = null;
        }
        return Task.CompletedTask;
    }

    // ------------------------------------------------------------------
    // PR 9.12 §2.13 Step 7 — lifecycle bodies lifted off RiverWindowManagerClient.
    // Each operates on the still-resident god-class transport fields via
    // internal accessors; the client retains thin forwarders so existing
    // call sites (RegistryGlobalBinder, NativeCallbackContext, tests)
    // compile unchanged.
    // ------------------------------------------------------------------

    internal unsafe Result Connect()
    {
        var client = _client ?? throw new InvalidOperationException("Connect called before client was resolved.");
        var connectResult = client.Connection.Connect();
        if (!connectResult.IsOk)
        {
            RiverLog.Write("wl_display_connect failed: " + connectResult.Error);
            return connectResult;
        }

        WlInterfaces.EnsureBuilt();

        // Allocate a NativeCallbackContext (which performs the actual
        // GCHandle.Alloc internally) and rehydrate SelfHandle from its
        // IntPtr so all call sites that still read GCHandle.ToIntPtr(SelfHandle)
        // continue to round-trip to the context.
        var ctx = new Aqueous.Features.Compositor.River.Dispatch.NativeCallbackContext(
            client.RiverEventDispatcher, client);
        client.CallbackContext = ctx;
        client.SelfHandle = GCHandle.FromIntPtr(ctx.Handle);
        client.KeyBindingsRegistryRef.SelfHandlePtr = GCHandle.ToIntPtr(client.SelfHandle);

        IntPtr dispatcher = (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)
            &Aqueous.Features.Compositor.River.Dispatch.NativeCallbackEntry.Dispatch;

        if (!client.RegistryBinder.Create(client.Display, dispatcher, GCHandle.ToIntPtr(client.SelfHandle)))
        {
            RiverLog.Write("get_registry failed");
            return Result.Fail("wl_display_get_registry returned null");
        }

        client.BindSiteState.TrackProxyInterface(client.RegistryBinder.Handle, "wl_registry");

        // PR 9.12 §2.13 Step 7: route registry globals directly to the
        // host's HandleRegistryGlobal instead of round-tripping through
        // the god-class RegistryGlobalBinder forwarder.
        client.RegistryBinder.Discovered += HandleRegistryGlobal;

        // Flush globals; then a second roundtrip so any events the
        // compositor sends immediately on bind (for an existing window
        // list) are delivered before we return.
        client.Connection.Roundtrip();
        client.Connection.Roundtrip();

        if (client.Manager == IntPtr.Zero)
        {
            return Result.Fail(
                "river_window_manager_v1 global was not advertised — is RiverDelta running with WM support?");
        }

        return Result.Ok;
    }

    internal void StartPump(CancellationToken cancellationToken = default)
    {
        var client = _client ?? throw new InvalidOperationException("StartPump called before client was resolved.");
        client.Pump.Start(cancellationToken);
    }

    internal void DisposeWayland()
    {
        var client = _client;
        if (client is null) return;
        // river_window_manager_v1::stop (opcode 0) is intentionally NOT
        // sent here: it is not a destructor. We disconnect; River treats
        // a disconnected WM the same way as a stopped one and cleans up.
        try
        {
            // Critical ordering: stop the pump first so it is no longer
            // touching wl_display, then dispose the connection.
            client.Pump.Stop(PumpJoinTimeout);
            client.Connection.Dispose();

            client.WindowRegistry.Clear();
            client.OutputRegistry.Clear();
            client.SeatRegistry.Clear();
        }
        catch
        {
            // Tear-down is best-effort; never let Dispose throw.
        }
        finally
        {
            if (client.CallbackContext is { } ctx)
            {
                ctx.Dispose();
                client.CallbackContext = null;
            }
            else if (client.SelfHandle.IsAllocated)
            {
                var h = client.SelfHandle;
                h.Free();
                client.SelfHandle = default;
            }
        }
    }

    internal unsafe void HandleRegistryGlobal(RegistryGlobal global)
    {
        var client = _client ?? throw new InvalidOperationException("HandleRegistryGlobal called before client was resolved.");
        IntPtr dispatcher = (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)
            &Aqueous.Features.Compositor.River.Dispatch.NativeCallbackEntry.Dispatch;

        if (global.Interface == "river_window_manager_v1" && client.Manager == IntPtr.Zero)
        {
            var managerVersion = Math.Min(global.Version, 4u);
            client.SetManagerVersion(managerVersion);
            client.Manager = client.RegistryBinder.Bind(global.Name, WlInterfaces.RiverWindowManager, managerVersion);
            client.BindSiteState.Manager = client.Manager;
            if (client.Manager != IntPtr.Zero)
            {
                WaylandInterop.wl_proxy_add_dispatcher(
                    client.Manager,
                    dispatcher,
                    GCHandle.ToIntPtr(client.SelfHandle),
                    IntPtr.Zero);
                client.BindSiteState.TrackProxyInterface(client.Manager, "river_window_manager_v1");
                client.ManagerRequestSender.Init(client.Manager, client.Display);
                RiverLog.Write($"bound river_window_manager_v1 (version {managerVersion})");
            }
        }
        else if (global.Interface == "river_layer_shell_v1")
        {
            client.LayerShell = client.RegistryBinder.Bind(global.Name, WlInterfaces.RiverLayerShell, 1);
            client.BindSiteState.LayerShell = client.LayerShell;
            WaylandInterop.wl_proxy_add_dispatcher(
                client.LayerShell,
                dispatcher,
                GCHandle.ToIntPtr(client.SelfHandle),
                IntPtr.Zero);
            client.BindSiteState.TrackProxyInterface(client.LayerShell, "river_layer_shell_v1");
            RiverLog.Write("bound river_layer_shell_v1");
        }
        else if (global.Interface == "river_xkb_bindings_v1")
        {
            uint xkbVersion = Math.Min(global.Version, 2u);
            client.XkbBindingsHandle = client.RegistryBinder.Bind(global.Name, WlInterfaces.RiverXkbBindings, xkbVersion);
            client.BindSiteState.XkbBindings = client.XkbBindingsHandle;
            client.XkbBindingsVersion = xkbVersion;
            client.BindSiteState.XkbBindingsVersion = xkbVersion;
            client.BindSiteState.TrackProxyInterface(client.XkbBindingsHandle, "river_xkb_bindings_v1");
            RiverLog.Write($"bound river_xkb_bindings_v1 (version {xkbVersion})");
        }
        else if (global.Interface == "wl_shm" && client.WlShm == IntPtr.Zero)
        {
            client.WlShm = client.RegistryBinder.Bind(global.Name, WlInterfaces.WlShm, 1);
            client.BindSiteState.WlShm = client.WlShm;
            client.BindSiteState.TrackProxyInterface(client.WlShm, "wl_shm");
            RiverLog.Write("bound wl_shm");
            client.ScreencopyService.ActivateIfReady(
                client.BindSiteState,
                client.ScreencopyVersion,
                GCHandle.ToIntPtr(client.SelfHandle),
                dispatcher,
                RiverLog.Write);
        }
        else if (global.Interface == "wl_output")
        {
            // Lazy-bind path: only remember the global. Real wl_output
            // proxies are bound on-demand from CaptureOutputAsync and
            // destroyed immediately after capture.
            client.WlOutputGlobals[global.Name] = global;
        }
        else if (global.Interface == "zwlr_screencopy_manager_v1" && client.ScreencopyManager == IntPtr.Zero)
        {
            var version = Math.Min(global.Version, 3u);
            client.ScreencopyVersion = version;
            client.ScreencopyManager = client.RegistryBinder.Bind(
                global.Name, WlInterfaces.ZwlrScreencopyManager, version);
            client.BindSiteState.ScreencopyManager = client.ScreencopyManager;
            client.BindSiteState.TrackProxyInterface(client.ScreencopyManager, "zwlr_screencopy_manager_v1");
            RiverLog.Write($"bound zwlr_screencopy_manager_v1 (version {version})");
            client.ScreencopyService.ActivateIfReady(
                client.BindSiteState,
                version,
                GCHandle.ToIntPtr(client.SelfHandle),
                dispatcher,
                RiverLog.Write);
        }
    }
}
