using System;
using System.Runtime.InteropServices;
using System.Threading;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Aqueous.Features.Compositor.River.Dispatch.Services;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Aqueous;

class Program
{
    static int Main(string[] args)
    {
        // Configure logging from AQUEOUS_LOG=trace|debug|info|warn|error.
        Logging.ConfigureFromEnvironment();
        var log = Logging.For<Program>();

        log.LogInformation("Starting standalone River Window Manager client...");
        log.LogInformation(
            "primary modifier = {Name} (mask=0x{Mask:x}, keysym=0x{Sym:x}, AQUEOUS_MOD={Env})",
            Mods.PrimaryName, Mods.PrimaryMask, Mods.PrimaryKeysym,
            Environment.GetEnvironmentVariable("AQUEOUS_MOD") ?? "<unset>");

        using var lifetimeCts = new CancellationTokenSource();

        // Final demolition. The RiverWindowManagerClient god class is gone. Every service it formerly
        // built in its ctor is now registered directly with DI. RiverCompositorHost takes the same ctor
        // args via DI and owns the Wayland lifecycle outright.
        var services = new ServiceCollection();
        services.AddSingleton(typeof(ILoggerFactory),
            (object?)Logging.Factory ?? NullLoggerFactory.Instance);
        services.AddSingleton(typeof(ILogger<>), typeof(Logger<>));

        // - Connection & transport state ---------------------------------
        services.AddSingleton<IWaylandConnection, WaylandConnection>();
        services.AddSingleton<IWindowRegistry, WindowRegistry>();
        services.AddSingleton<IShellSurfaceRegistry, ShellSurfaceRegistry>();
        services.AddSingleton<ILayerShellUsableAreaStore, LayerShellUsableAreaStore>();
        services.AddSingleton<Aqueous.Features.Focus.ILayerShellFocusState,
            Aqueous.Features.Focus.LayerShellFocusState>();
        services.AddSingleton<Aqueous.Features.Compositor.River.ILayerShellTeardownService,
            Aqueous.Features.Compositor.River.LayerShellTeardownService>();
        services.AddSingleton<IOutputRegistry, OutputRegistry>();
        services.AddSingleton<ISeatRegistry, SeatRegistry>();
        // EventPumpOptions wires three pump-thread callbacks to IManagerRequestSender so that
        // off-pump callers (KeyBindingRouter, drag pointer handlers, etc.) can post manage_dirty
        // hints onto a queue drained on the dispatch thread — preventing the wl_proxy_marshal_flags
        // / wl_display_dispatch race that surfaced as `segfault at 2c … in libwayland-client`.
        services.AddSingleton<EventPumpOptions>(sp =>
        {
            var sender = sp.GetRequiredService<Aqueous.Features.Layout.IManagerRequestSender>();
            var workspaces = sp.GetRequiredService<Aqueous.Features.Workspaces.IWorkspaceService>();
            return new EventPumpOptions
            {
                OnPumpThreadStart = () => sender.SetPumpThread(System.Threading.Thread.CurrentThread.ManagedThreadId),
                // Drain the off-pump action queue, then flush any workspace switch the rapid-switch
                // debounce coalesced — both run once per dispatch iteration on the pump thread.
                OnDispatchIteration = () =>
                {
                    sender.DrainPumpQueue();
                    workspaces.FlushPending();
                },
                OnPumpThreadStop = () => sender.SetPumpThread(0),
            };
        });
        services.AddSingleton<IEventPump, EventPump>();
        services.AddSingleton<WaylandBindSiteState>();
        services.AddSingleton<RegistryBinder>();

        // - Fine-grained state singletons --------------------------------
        services.AddSingleton<Aqueous.Features.Focus.FocusedWindowTracker>();
        services.AddSingleton<Aqueous.Features.State.OutputFullscreenMap>();
        services.AddSingleton<Aqueous.Features.State.WindowStateStore>();
        services.AddSingleton<Aqueous.Features.Focus.PendingFocusStore>();
        services.AddSingleton<Aqueous.Features.Focus.PrimarySeatTracker>();
        services.AddSingleton<Aqueous.Features.Input.DragStateStore>();
        services.AddSingleton<Aqueous.Features.Input.LibinputConfigApplier>();
        services.AddSingleton<Aqueous.Features.State.PrevFullscreenStore>();
        services.AddSingleton<Aqueous.Features.Bindings.KeyBindingsRegistry>();
        services.AddSingleton<Aqueous.Features.Input.PointerBindingStore>();
        services.AddSingleton<Aqueous.Features.State.ManageCycleState>();
        services.AddSingleton<Aqueous.Features.State.ScratchpadRegistry>();

        // - Rules subsystem ----------------------------------------------
        // Loads rules.toml at boot via the documented discovery order; falls back to
        // RulesConfig.Empty when no file is present. The engine is a singleton consumed by
        // WindowEventService on app_id / title transitions and queried by LayoutProposer
        // implicitly via WindowEntry.Placement.
        services.AddSingleton<Aqueous.Features.Rules.RulesConfig>(_ =>
            Aqueous.Features.Rules.RulesTomlReader.Load());
        services.AddSingleton<Aqueous.Features.Rules.IWindowRuleEngine>(sp =>
            new Aqueous.Features.Rules.WindowRuleEngine(
                sp.GetRequiredService<Aqueous.Features.Rules.RulesConfig>().Windows));
        // Visible reload-confirmation notifications. Shells out to `notify-send`; if the
        // user has no notifier daemon running (mako/dunst/fnott), the call is logged and
        // swallowed — reload itself still succeeds. See INotificationPublisher.
        services.AddSingleton<Aqueous.Features.Rules.INotificationPublisher,
            Aqueous.Features.Rules.NotifySendPublisher>();
        // Hot-reload entry point — bound to Super+R (alongside wm.toml reload) and to the
        // optional standalone `reload_rules` keybind verb.
        services.AddSingleton<Aqueous.Features.Rules.IRulesReloader,
            Aqueous.Features.Rules.RulesReloader>();

        // - Layout subsystem ---------------------------------------------
        services.AddSingleton<Aqueous.Features.Layout.LayoutRegistry>();
        services.AddSingleton<Aqueous.Features.Layout.LayoutConfig>(_ =>
        {
            // Base config from wm.toml (+ optional layout.toml sidecar), then overlay an optional
            // standalone input.toml on top of the [input] block (sidecar wins per field it sets).
            var baseCfg = Aqueous.Features.Layout.LayoutTomlReader.LoadWithSidecar(DefaultConfigPath.Resolve());
            var inputOverlay = Aqueous.Features.Input.InputTomlReader.Load();
            return baseCfg with { Input = Aqueous.Features.Input.InputTomlReader.Merge(baseCfg.Input, inputOverlay) };
        });
        services.AddSingleton<Aqueous.Features.Layout.LayoutController>();
        services.AddSingleton<Aqueous.Features.Layout.IManagerRequestSender,
            Aqueous.Features.Layout.ManagerRequestSender>();
        services.AddSingleton<Aqueous.Features.Layout.ILayoutProposer,
            Aqueous.Features.Layout.LayoutProposer>();
        services.AddSingleton<Aqueous.Features.Layout.ViewportInteractionService>();

        // - Focus / Tags / Screencopy ------------------------------------
        services.AddSingleton<Aqueous.Features.Focus.IFocusService,
            Aqueous.Features.Focus.FocusService>();
        services.AddSingleton<Aqueous.Features.Tags.ITagService,
            Aqueous.Features.Tags.TagService>();
        services.AddSingleton<Aqueous.Features.Workspaces.WorkspaceStore>();
        services.AddSingleton<Aqueous.Features.Workspaces.WorkspaceEventService>();
        services.AddSingleton<Aqueous.Features.Workspaces.IWorkspaceService,
            Aqueous.Features.Workspaces.WorkspaceService>();
        services.AddSingleton<Aqueous.Features.Screencopy.IScreencopyService,
            Aqueous.Features.Screencopy.ScreencopyService>();

        // - Seat / drag ---------------------------------------------------
        services.AddSingleton<SeatInteractionService>();
        services.AddSingleton<Aqueous.Features.Input.DragPointerBindingService>();

        // - Bindings ------------------------------------------------------
        services.AddSingleton<Aqueous.Features.Bindings.IProcessLauncher,
            Aqueous.Features.Bindings.ProcessLauncher>();
        services.AddSingleton<Aqueous.Features.Bindings.IKeyBindingRouter,
            Aqueous.Features.Bindings.KeyBindingRouter>();
        services.AddSingleton<Aqueous.Features.Bindings.ICustomActionRunner,
            Aqueous.Features.Bindings.CustomActionRunner>();
        services.AddSingleton<Aqueous.Features.Bindings.KeyBindingRegistrar>();
        services.AddSingleton<Aqueous.Features.Bindings.IKeyBindingRegistrar>(sp =>
            sp.GetRequiredService<Aqueous.Features.Bindings.KeyBindingRegistrar>());

        // - Window-state subsystem ---------------------------------------
        services.AddSingleton<Aqueous.Features.State.WindowStateHost>();
        services.AddSingleton<Aqueous.Features.State.IWindowStateHost>(sp =>
            sp.GetRequiredService<Aqueous.Features.State.WindowStateHost>());
        services.AddSingleton<Aqueous.Features.State.WindowStateController>();
        // Break the FocusService -> WindowStateController -> IWindowStateHost -> IFocusService DI
        // cycle by deferring WindowStateController resolution past FocusService construction.
        services.AddSingleton<Lazy<Aqueous.Features.State.WindowStateController>>(sp =>
            new Lazy<Aqueous.Features.State.WindowStateController>(
                sp.GetRequiredService<Aqueous.Features.State.WindowStateController>));
        services.AddSingleton<Aqueous.Features.Startup.StartupExecRunner>(sp =>
            new Aqueous.Features.Startup.StartupExecRunner(
                sp.GetRequiredService<Aqueous.Features.State.IWindowStateHost>(),
                sp.GetRequiredService<Aqueous.Features.Layout.LayoutConfig>().Exec));

        // - Manager / window event services ------------------------------
        services.AddSingleton<ManagerEventService>();
        services.AddSingleton<WindowEventService>();

        // - Event-handler registrations (the dispatcher table) -----------
        services.AddSingleton<IEventHandler>(sp => new LayerShellSeatEventHandler(
            sp.GetRequiredService<Aqueous.Features.Focus.ILayerShellFocusState>(),
            sp.GetRequiredService<WaylandBindSiteState>(),
            sp.GetRequiredService<Aqueous.Features.Focus.IFocusService>(),
            RiverLog.Write));
        services.AddSingleton<IEventHandler>(sp => new LayerShellOutputEventHandler(
            sp.GetRequiredService<ILayerShellUsableAreaStore>(),
            sp.GetRequiredService<WaylandBindSiteState>(),
            RiverLog.Write));
        services.AddSingleton<IEventHandler>(sp => new OutputEventHandler(
            sp.GetRequiredService<IWindowRegistry>(),
            sp.GetRequiredService<IOutputRegistry>(),
            sp.GetRequiredService<Aqueous.Features.State.WindowStateStore>(),
            sp.GetRequiredService<Aqueous.Features.State.WindowStateController>(),
            sp.GetRequiredService<Aqueous.Features.State.OutputFullscreenMap>(),
            sp.GetRequiredService<Aqueous.Features.Compositor.River.ILayerShellTeardownService>(),
            RiverLog.Write));
        services.AddSingleton<IEventHandler>(sp =>
        {
            var drag = sp.GetRequiredService<Aqueous.Features.Input.DragStateStore>();
            return new SeatEventHandler(
                sp.GetRequiredService<ISeatRegistry>(),
                sp.GetRequiredService<IWindowRegistry>(),
                drag.SeatHoveredWindow,
                drag.SeatPointerPos,
                sp.GetRequiredService<SeatInteractionService>(),
                RiverLog.Write);
        });
        services.AddSingleton<IEventHandler>(sp => new ShellSurfaceEventHandler(
            sp.GetRequiredService<SeatInteractionService>()));
        services.AddSingleton<IEventHandler>(sp => new WindowEventHandler(
            sp.GetRequiredService<IWindowRegistry>(),
            sp.GetRequiredService<WindowEventService>(),
            RiverLog.Write));
        services.AddSingleton<IEventHandler>(sp => new ManagerEventHandler(
            sp.GetRequiredService<ManagerEventService>(),
            RiverLog.Write));
        services.AddSingleton<IEventHandler>(_ => new SuperKeyBindingEventHandler(RiverLog.Write));
        services.AddSingleton<IEventHandler>(sp => new DragPointerBindingEventHandler(
            sp.GetRequiredService<Aqueous.Features.Input.DragPointerBindingService>(),
            RiverLog.Write));
        services.AddSingleton<IEventHandler>(sp => new RegistryEventHandler(
            sp.GetRequiredService<RegistryBinder>(),
            RiverLog.Write));
        services.AddSingleton<IEventHandler>(sp => new KeyBindingEventHandler(
            sp.GetRequiredService<Aqueous.Features.Bindings.KeyBindingRegistrar>(),
            RiverLog.Write));
        services.AddSingleton<IEventHandler>(sp => new ScreencopyFrameHandler(
            sp.GetRequiredService<Aqueous.Features.Screencopy.IScreencopyService>(),
            RiverLog.Write));
        services.AddSingleton<IEventHandler>(sp => new LibinputConfigEventHandler(
            sp.GetRequiredService<Aqueous.Features.Input.LibinputConfigApplier>(),
            sp.GetRequiredService<WaylandBindSiteState>(),
            sp.GetRequiredService<Aqueous.Features.Bindings.KeyBindingsRegistry>(),
            RiverLog.Write));
        services.AddSingleton<IEventHandler>(sp => new LibinputDeviceEventHandler(
            sp.GetRequiredService<Aqueous.Features.Input.LibinputConfigApplier>(),
            RiverLog.Write));
        services.AddSingleton<IEventHandler>(sp => new Aqueous.Features.Workspaces.ExtWorkspaceManagerEventHandler(
            sp.GetRequiredService<Aqueous.Features.Workspaces.WorkspaceEventService>()));
        services.AddSingleton<IEventHandler>(sp => new Aqueous.Features.Workspaces.ExtWorkspaceGroupEventHandler(
            sp.GetRequiredService<Aqueous.Features.Workspaces.WorkspaceEventService>()));
        services.AddSingleton<IEventHandler>(sp => new Aqueous.Features.Workspaces.ExtWorkspaceHandleEventHandler(
            sp.GetRequiredService<Aqueous.Features.Workspaces.WorkspaceEventService>()));

        // - Top-level dispatcher + host ----------------------------------
        services.AddSingleton<IEventDispatcher>(sp => new EventDispatcher(
            sp.GetServices<IEventHandler>()));
        services.AddSingleton<RiverCompositorHost>();

        using var provider = services.BuildServiceProvider();

        // Seed the libinput applier with the startup config. Devices appear asynchronously after
        // RiverCompositorHost binds the river_libinput_config_v1 global; the applier will apply this
        // config the first time each device emits its done event. Reload from KeyBindingRouter calls
        // Apply again to push wm.toml changes to all currently-known devices.
        try
        {
            var cfg = provider.GetRequiredService<Aqueous.Features.Layout.LayoutConfig>();
            provider.GetRequiredService<Aqueous.Features.Input.LibinputConfigApplier>().Apply(cfg.Input);
        }
        catch (Exception ex)
        {
            log.LogWarning(ex, "LibinputConfigApplier.Apply failed");
        }

        Console.CancelKeyPress += (_, e) =>
        {
            log.LogInformation("SIGINT received; shutting down...");
            e.Cancel = true;
            lifetimeCts.Cancel();
        };

        using var sigterm = PosixSignalRegistration.Create(PosixSignal.SIGTERM, ctx =>
        {
            log.LogInformation("SIGTERM received; shutting down...");
            ctx.Cancel = true;
            lifetimeCts.Cancel();
        });

        var host = provider.GetRequiredService<RiverCompositorHost>();
        try
        {
            host.StartAsync(lifetimeCts.Token).GetAwaiter().GetResult();
        }
        catch (InvalidOperationException ex)
        {
            log.LogError(
                "Failed to connect to River as window manager: {Error}. Are you running inside River with AQUEOUS_RIVER_WM=1?",
                ex.Message);
            return 1;
        }

        log.LogInformation("Connected. Entering event loop.");

        try
        {
            lifetimeCts.Token.WaitHandle.WaitOne();
        }
        finally
        {
            host.StopAsync(CancellationToken.None).GetAwaiter().GetResult();
        }

        return 0;
    }
}
