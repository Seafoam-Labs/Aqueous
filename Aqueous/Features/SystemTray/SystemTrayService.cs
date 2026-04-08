using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Tmds.DBus.Protocol;

namespace Aqueous.Features.SystemTray
{
    public class SystemTrayService : IDisposable
    {
        private DBusConnection? _connection;
        private StatusNotifierWatcher? _watcher;
        private StatusNotifierHost? _host;

        public event Action? ItemsChanged;
        public IReadOnlyList<TrayItem> Items => _host?.Items ?? Array.Empty<TrayItem>();
        public StatusNotifierHost? Host => _host;

        public void Start()
        {
            Task.Run(async () =>
            {
                try
                {
                    _connection = new DBusConnection(DBusAddress.Session!);
                    await _connection.ConnectAsync();
                    Console.Error.WriteLine("[SystemTray] Connected to session bus");

                    // Check if a watcher already exists on the bus
                    bool watcherExists = false;
                    try
                    {
                        await DBusHelper.GetPropertyAsync(
                            _connection, "org.kde.StatusNotifierWatcher",
                            "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
                            "IsStatusNotifierHostRegistered");
                        watcherExists = true;
                        Console.Error.WriteLine("[SystemTray] Existing watcher found on bus");
                    }
                    catch
                    {
                        Console.Error.WriteLine("[SystemTray] No existing watcher found, registering our own");
                    }

                    if (!watcherExists)
                    {
                        // No existing watcher — register our own
                        _watcher = new StatusNotifierWatcher(_connection);
                        _connection.AddMethodHandler(_watcher);
                        await DBusHelper.RequestNameAsync(_connection, "org.kde.StatusNotifierWatcher");
                        _watcher.RegisterHostInternal("com.example.aqueous");
                        Console.Error.WriteLine("[SystemTray] Registered own watcher");
                    }
                    else
                    {
                        // Register ourselves as a host on the existing watcher
                        await DBusHelper.CallMethodStringAsync(
                            _connection, "org.kde.StatusNotifierWatcher",
                            "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
                            "RegisterStatusNotifierHost", "com.example.aqueous");
                        Console.Error.WriteLine("[SystemTray] Registered as host on existing watcher");
                    }

                    // Create host — pass local watcher (null if using existing)
                    _host = new StatusNotifierHost(_connection, _watcher);
                    _host.ItemsChanged += () => ItemsChanged?.Invoke();
                    await _host.StartAsync();

                    Console.Error.WriteLine($"[SystemTray] Host started, initial items: {_host.Items.Count}");

                    // Emit initial ItemsChanged so the widget rebuilds
                    GLib.Functions.IdleAdd(0, () => { ItemsChanged?.Invoke(); return false; });
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"[SystemTray] Failed to start: {ex}");
                }
            });
        }

        public void Dispose()
        {
            _host?.Dispose();
            _connection?.Dispose();
        }
    }
}
