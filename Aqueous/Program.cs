using System;
using System.Runtime.InteropServices;
using System.Threading;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Registry;
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

        // Single CTS drives shutdown for both Ctrl+C (SIGINT) and SIGTERM.
        // Threaded through RiverCompositorHost.StartAsync so the pump
        // observes the same token (PR 9.11: the lifetime is now owned
        // by the host, not the DI factory).
        using var lifetimeCts = new CancellationTokenSource();

        // Build the DI container. Stage 9 PR 9.1 completes the long-standing
        // "fix DI" tech debt by registering RiverWindowManagerClient itself
        // as a singleton + adding factory-lambda registrations for every
        // service and IEventHandler it owns. After this PR, external
        // consumers + tests can resolve any of these via
        // provider.GetRequiredService<IXxx>() instead of reaching through
        // the god class. The accessor properties on RiverWindowManagerClient
        // disappear in PR 9.12 once each service is registered standalone.
        var services = new ServiceCollection();
        services.AddSingleton(typeof(ILoggerFactory),
            (object?)Logging.Factory ?? NullLoggerFactory.Instance);
        services.AddSingleton(typeof(ILogger<>), typeof(Logger<>));
        services.AddSingleton<IWaylandConnection, WaylandConnection>();
        services.AddSingleton<IWindowRegistry, WindowRegistry>();
        services.AddSingleton<IOutputRegistry, OutputRegistry>();
        services.AddSingleton<ISeatRegistry, SeatRegistry>();
        services.AddSingleton<EventPumpOptions>();
        services.AddSingleton<IEventPump, EventPump>();

        // Stage 9 PR 9.12 §2.1: WaylandBindSiteState is the new owner of
        // raw bind-site proxy pointers (manager / layer-shell / screencopy
        // / wl_shm / xkb-bindings) plus the proxy → interface-name map.
        // Registered as a singleton so consumers can ctor-inject it
        // directly in subsequent §2.x steps; the god class still mirrors
        // writes into the legacy private fields during the migration.
        services.AddSingleton<WaylandBindSiteState>();

        // Stage 9 PR 9.12 §2.2: FocusedWindowTracker owns the raw
        // focused-window proxy pointer (formerly RiverWindowManagerClient
        // ._focusedWindow). The god class still exposes the property
        // alias during the migration.
        services.AddSingleton<Aqueous.Features.Focus.FocusedWindowTracker>();

        // Stage 9 PR 9.11: register the god class as a DI singleton built
        // via its DI ctor — *not* TryStart. The factory only assembles
        // the object graph; Connect + StartPump now run from
        // RiverCompositorHost.StartAsync (the host owns the lifecycle).
        // This separation makes construction failures and connection
        // failures observable independently and removes the "resolving
        // a service opens a Wayland connection" side-effect that PR 9.1
        // had to live with as scaffolding.
        services.AddSingleton<RiverWindowManagerClient>(sp =>
            new RiverWindowManagerClient(
                (IWaylandConnection?)sp.GetService(typeof(IWaylandConnection)) ?? new WaylandConnection(),
                (IWindowRegistry?)sp.GetService(typeof(IWindowRegistry)) ?? new WindowRegistry(),
                (IOutputRegistry?)sp.GetService(typeof(IOutputRegistry)) ?? new OutputRegistry(),
                (ISeatRegistry?)sp.GetService(typeof(ISeatRegistry)) ?? new SeatRegistry(),
                (Aqueous.Features.Compositor.River.Connection.IEventPump?)sp.GetService(typeof(Aqueous.Features.Compositor.River.Connection.IEventPump)),
                sp.GetRequiredService<WaylandBindSiteState>(),
                sp.GetRequiredService<Aqueous.Features.Focus.FocusedWindowTracker>()));

        // Stage 9 PR 9.1: every service the god class owns is now
        // resolvable from DI via a factory lambda that reads it off the
        // singleton RiverWindowManagerClient. Behaviour-preserving — no
        // service is constructed twice; these factories return the same
        // instance the god class ctor created. Registrations retire one
        // at a time in PRs 9.2–9.12 as state migrates out of the bridge.
        // PR 9.3 Stage 9: RegistryBinder is now DI-resolvable (consumed
        // by RegistryEventHandler directly — IRegistryHandlerCollaborators
        // bridge retired).
        services.AddSingleton<Aqueous.Features.Compositor.River.Connection.RegistryBinder>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().RegistryBinder);
        services.AddSingleton<IEventDispatcher>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().EventDispatcher);
        services.AddSingleton<Aqueous.Features.Focus.IFocusService>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().FocusService);
        services.AddSingleton<Aqueous.Features.Tags.ITagService>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().TagService);
        services.AddSingleton<Aqueous.Features.Layout.IManagerRequestSender>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().ManagerRequestSender);
        services.AddSingleton<Aqueous.Features.Layout.ILayoutProposer>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().LayoutProposer);
        services.AddSingleton<Aqueous.Features.SnapZones.ISnapZoneService>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().SnapZoneService);
        services.AddSingleton<Aqueous.Features.Screencopy.IScreencopyService>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().ScreencopyService);
        services.AddSingleton<Aqueous.Features.Bindings.IProcessLauncher>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().ProcessLauncher);
        services.AddSingleton<Aqueous.Features.Bindings.ICustomActionRunner>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().CustomActionRunner);
        services.AddSingleton<Aqueous.Features.Bindings.IKeyBindingRegistrar>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().KeyBindingRegistrar);
        services.AddSingleton<Aqueous.Features.Bindings.IKeyBindingRouter>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().KeyBindingRouter);

        // Stage 9 PR 9.1: each IEventHandler the dispatcher uses is now a
        // first-class DI registration. The placeholder
        // AddSingleton<IEventHandler, LayerShellEventHandler>() that
        // existed since PR 8.1 (and was constructing a second, unwired
        // instance) is removed.
        services.AddSingleton<Aqueous.Features.Compositor.River.Dispatch.IEventHandler>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().LayerShellHandler);
        services.AddSingleton<Aqueous.Features.Compositor.River.Dispatch.IEventHandler>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().OutputHandler);
        services.AddSingleton<Aqueous.Features.Compositor.River.Dispatch.IEventHandler>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().SeatHandler);
        services.AddSingleton<Aqueous.Features.Compositor.River.Dispatch.IEventHandler>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().WindowHandler);
        services.AddSingleton<Aqueous.Features.Compositor.River.Dispatch.IEventHandler>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().ManagerHandler);
        services.AddSingleton<Aqueous.Features.Compositor.River.Dispatch.IEventHandler>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().SuperKeyBindingHandler);
        services.AddSingleton<Aqueous.Features.Compositor.River.Dispatch.IEventHandler>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().DragPointerBindingHandler);
        services.AddSingleton<Aqueous.Features.Compositor.River.Dispatch.IEventHandler>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().RegistryHandler);
        services.AddSingleton<Aqueous.Features.Compositor.River.Dispatch.IEventHandler>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().KeyBindingHandler);
        services.AddSingleton<Aqueous.Features.Compositor.River.Dispatch.IEventHandler>(sp =>
            sp.GetRequiredService<RiverWindowManagerClient>().ScreencopyFrameHandler);

        // Stage 9 PR 9.2: register the IHostedService shell. Constructed
        // lazily; StartAsync/StopAsync is driven manually from Main below
        // (we deliberately avoid pulling in the full Generic Host here to
        // keep the SIGINT/SIGTERM signal wiring intact). PRs 9.3–9.12
        // progressively move Connect/Dispose responsibilities onto the host.
        services.AddSingleton<Aqueous.Features.Compositor.River.RiverCompositorHost>();

        using var provider = services.BuildServiceProvider();

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

        // Stage 9 PR 9.11: drive startup + shutdown through the
        // RiverCompositorHost IHostedService shell. StartAsync now
        // checks the env-var guard, builds the client via DI, calls
        // Connect (registry roundtrip + globals + startup exec) and
        // StartPump. StopAsync disposes the client (which stops the
        // pump and closes the connection).
        var host = provider.GetRequiredService<Aqueous.Features.Compositor.River.RiverCompositorHost>();
        try
        {
            host.StartAsync(lifetimeCts.Token).GetAwaiter().GetResult();
        }
        catch (InvalidOperationException ex)
        {
            // PR 9.11: the host throws InvalidOperationException whose
            // Message carries the friendly error (env-var missing,
            // Connect failed, libwayland missing). Surface it directly
            // instead of relying on the prior `startupFailure` closure
            // that was set inside the now-removed TryStart DI factory.
            log.LogError(
                "Failed to connect to River as window manager: {Error}. Are you running inside River with AQUEOUS_RIVER_WM=1?",
                ex.Message);
            return 1;
        }

        log.LogInformation("Connected. Entering event loop.");

        // Block the main thread; the pump runs on its own background
        // thread and observes lifetimeCts.Token directly.
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
