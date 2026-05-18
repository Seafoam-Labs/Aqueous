using System;
using System.Runtime.InteropServices;
using System.Threading;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Connection;
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

        // Build the DI container. The set of registrations here matches
        // the seams promoted out of the RiverWindowManagerClient god class
        // to date: IWaylandConnection and the three I*Registry services.
        // Further extractions (EventPump, TagController, ...) will land in
        // their own PRs and add singletons here alongside these.
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
        using var provider = services.BuildServiceProvider();

        // Single CTS drives shutdown for both Ctrl+C (SIGINT) and SIGTERM.
        using var lifetimeCts = new CancellationTokenSource();

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

        // B1a: become a river_window_manager_v1 client.
        var startResult = RiverWindowManagerClient.TryStart(provider, lifetimeCts.Token);
        if (!startResult.IsOk)
        {
            log.LogError(
                "Failed to connect to River as window manager: {Error}. Are you running inside River with AQUEOUS_RIVER_WM=1?",
                startResult.Error);
            return 1;
        }

        var wm = startResult.Value!;
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
