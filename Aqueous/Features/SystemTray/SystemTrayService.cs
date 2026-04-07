using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Tmds.DBus;

namespace Aqueous.Features.SystemTray
{
    public class SystemTrayService : IDisposable
    {
        private Connection? _connection;
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
                    _connection = new Connection(Address.Session);
                    await _connection.ConnectAsync();

                    _watcher = new StatusNotifierWatcher();
                    await _connection.RegisterObjectAsync(_watcher);
                    await _connection.RegisterServiceAsync("org.kde.StatusNotifierWatcher",
                        ServiceRegistrationOptions.ReplaceExisting);

                    _host = new StatusNotifierHost(_connection, _watcher);
                    _host.ItemsChanged += () => ItemsChanged?.Invoke();

                    await _watcher.RegisterStatusNotifierHostAsync("com.example.aqueous");
                    await _host.StartAsync();
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"[SystemTray] Failed to start: {ex.Message}");
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
