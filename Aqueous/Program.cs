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
        // Captured by the RiverWindowManagerClient DI factory below so
        // TryStart can plumb cancellation into the pump.
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

        // Stage 9 PR 9.1: register the god class as a DI singleton. The
        // factory invokes TryStart (which performs Connect + roundtrip +
        // StartPump) lazily on first resolve. Resolving any of the
        // service registrations below triggers this, ensuring a single
        // ordered startup.
        var startupFailure = (string?)null;
        services.AddSingleton<RiverWindowManagerClient>(sp =>
        {
            var result = RiverWindowManagerClient.TryStart(sp, lifetimeCts.Token);
            if (!result.IsOk)
            {
                startupFailure = result.Error;
                throw new InvalidOperationException(
                    "RiverWindowManagerClient.TryStart failed: " + result.Error);
            }
            return result.Value!;
        });

        // Stage 9 PR 9.1: every service the god class owns is now
        // resolvable from DI via a factory lambda that reads it off the
        // singleton RiverWindowManagerClient. Behaviour-preserving — no
        // service is constructed twice; these factories return the same
        // instance the god class ctor created. Registrations retire one
        // at a time in PRs 9.2–9.12 as state migrates out of the bridge.
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

        // B1a: become a river_window_manager_v1 client. Triggers the
        // singleton factory above which runs TryStart exactly once.
        RiverWindowManagerClient wm;
        try
        {
            wm = provider.GetRequiredService<RiverWindowManagerClient>();
        }
        catch (InvalidOperationException)
        {
            log.LogError(
                "Failed to connect to River as window manager: {Error}. Are you running inside River with AQUEOUS_RIVER_WM=1?",
                startupFailure ?? "<unknown>");
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
            wm.Dispose();
        }
        return 0;
    }
}
