using System;
using System.Threading;
using Aqueous.Features.Compositor.River;

namespace Aqueous.WM
{
    class Program
    {
        static void Main(string[] args)
        {
            Console.WriteLine("[Aqueous.WM] Starting standalone River Window Manager client...");
            Console.Error.WriteLine(
                $"[Aqueous.WM] primary modifier = {Mods.PrimaryName} " +
                $"(mask=0x{Mods.PrimaryMask:x}, keysym=0x{Mods.PrimaryKeysym:x}, " +
                $"AQUEOUS_MOD={Environment.GetEnvironmentVariable("AQUEOUS_MOD") ?? "<unset>"})");

            // B1a: become a river_window_manager_v1 client
            var wm = RiverWindowManagerClient.TryStart();
            if (wm == null)
            {
                Console.Error.WriteLine("[Aqueous.WM] Failed to connect to River as window manager. Are you running inside River with AQUEOUS_RIVER_WM=1?");
                Environment.Exit(1);
            }

            Console.WriteLine("[Aqueous.WM] Connected. Entering event loop.");

            // Keep the application running indefinitely while the Wayland connection remains active.
            // In a real scenario, you'd poll the Wayland display file descriptor using epoll or select,
            // or rely on a main loop wrapper. RiverWindowManagerClient has its own thread/loop in TryStart?
            // Let's check how it handles events. If it dispatches on its own thread, we just need to block.
            
            // We use an infinite loop or wait handle to keep the main thread alive.
            var resetEvent = new ManualResetEventSlim(false);
            Console.CancelKeyPress += (sender, e) =>
            {
                Console.WriteLine("[Aqueous.WM] Shutting down...");
                e.Cancel = true;
                resetEvent.Set();
            };

            resetEvent.Wait();
            wm.Dispose();
        }
    }
}
