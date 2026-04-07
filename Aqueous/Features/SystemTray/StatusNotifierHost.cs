using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Tmds.DBus;

namespace Aqueous.Features.SystemTray
{
    [DBusInterface("org.freedesktop.DBus")]
    public interface IDBus : IDBusObject
    {
        Task<IDisposable> WatchNameOwnerChangedAsync(
            Action<(string name, string oldOwner, string newOwner)> handler,
            Action<Exception>? onError = null);
    }

    public class StatusNotifierHost : IDisposable
    {
        private readonly Connection _connection;
        private readonly StatusNotifierWatcher _watcher;
        private readonly DBusMenuProxy _menuProxy;
        private readonly Dictionary<string, TrayItem> _items = new();
        private readonly List<IDisposable> _watches = new();

        public event Action? ItemsChanged;
        public IReadOnlyList<TrayItem> Items => _items.Values.ToList();
        public DBusMenuProxy MenuProxy => _menuProxy;

        public StatusNotifierHost(Connection connection, StatusNotifierWatcher watcher)
        {
            _connection = connection;
            _watcher = watcher;
            _menuProxy = new DBusMenuProxy(connection);
        }

        public async Task StartAsync()
        {
            _watcher.ItemRegistered += OnItemRegistered;
            _watcher.ItemUnregistered += OnItemUnregistered;

            // Watch for D-Bus name owner changes to detect app exits
            var dbus = _connection.CreateProxy<IDBus>("org.freedesktop.DBus", new ObjectPath("/org/freedesktop/DBus"));
            var watch = await dbus.WatchNameOwnerChangedAsync(change =>
            {
                if (string.IsNullOrEmpty(change.newOwner))
                {
                    // Name lost — check if it was a tray item
                    var toRemove = _items.Keys
                        .Where(k => k == change.name || k.StartsWith(change.name + "/"))
                        .ToList();
                    foreach (var key in toRemove)
                    {
                        _watcher.RemoveItem(key);
                    }
                }
            });
            _watches.Add(watch);

            // Pick up any already-registered items
            foreach (var service in _watcher.RegisteredItems)
            {
                OnItemRegistered(service);
            }
        }

        private void OnItemRegistered(string service)
        {
            if (_items.ContainsKey(service))
                return;

            var item = new TrayItem { ServiceName = service };

            // Parse service name — could be ":1.45" (unique name) or "org.kde.StatusNotifierItem-PID-N"
            // Some apps register with "busname/objectpath" format
            var parts = service.Split('/', 2);
            var busName = parts[0];
            var objPath = parts.Length > 1 ? "/" + parts[1] : "/StatusNotifierItem";
            item.ObjectPath = objPath;

            _items[service] = item;

            Task.Run(async () =>
            {
                try
                {
                    await LoadItemPropertiesAsync(busName, item);
                    await WatchItemSignalsAsync(busName, item);
                    GLib.Functions.IdleAdd(0, () => { ItemsChanged?.Invoke(); return false; });
                }
                catch { }
            });
        }

        private void OnItemUnregistered(string service)
        {
            if (_items.Remove(service))
            {
                GLib.Functions.IdleAdd(0, () => { ItemsChanged?.Invoke(); return false; });
            }
        }

        private async Task LoadItemPropertiesAsync(string busName, TrayItem item)
        {
            var proxy = _connection.CreateProxy<IStatusNotifierItem>(busName, new ObjectPath(item.ObjectPath));
            try
            {
                var props = await proxy.GetAllAsync();
                if (props.TryGetValue("Id", out var id)) item.Id = id as string ?? "";
                if (props.TryGetValue("Title", out var title)) item.Title = title as string ?? "";
                if (props.TryGetValue("Status", out var status)) item.Status = status as string ?? "Active";
                if (props.TryGetValue("Category", out var cat)) item.Category = cat as string ?? "";
                if (props.TryGetValue("IconName", out var iconName)) item.IconName = iconName as string ?? "";
                if (props.TryGetValue("IconThemePath", out var themePath) && themePath is string tp && !string.IsNullOrEmpty(tp))
                {
                    // Add custom icon theme path
                    var theme = Gtk.IconTheme.GetForDisplay(Gdk.Display.GetDefault()!);
                    theme.AddSearchPath(tp);
                }
                if (props.TryGetValue("Menu", out var menu) && menu is ObjectPath menuPath)
                    item.MenuPath = menuPath.ToString();
                else if (props.TryGetValue("Menu", out var menuStr) && menuStr is string ms)
                    item.MenuPath = ms;
            }
            catch { }
        }

        private async Task WatchItemSignalsAsync(string busName, TrayItem item)
        {
            var proxy = _connection.CreateProxy<IStatusNotifierItem>(busName, new ObjectPath(item.ObjectPath));
            try
            {
                var w1 = await proxy.WatchNewIconAsync(() =>
                {
                    Task.Run(async () =>
                    {
                        await LoadItemPropertiesAsync(busName, item);
                        GLib.Functions.IdleAdd(0, () => { ItemsChanged?.Invoke(); return false; });
                    });
                });
                _watches.Add(w1);

                var w2 = await proxy.WatchNewTitleAsync(() =>
                {
                    Task.Run(async () =>
                    {
                        await LoadItemPropertiesAsync(busName, item);
                        GLib.Functions.IdleAdd(0, () => { ItemsChanged?.Invoke(); return false; });
                    });
                });
                _watches.Add(w2);

                var w3 = await proxy.WatchNewStatusAsync(newStatus =>
                {
                    item.Status = newStatus;
                    GLib.Functions.IdleAdd(0, () => { ItemsChanged?.Invoke(); return false; });
                });
                _watches.Add(w3);
            }
            catch { }
        }

        public async Task ActivateItemAsync(TrayItem item)
        {
            try
            {
                var parts = item.ServiceName.Split('/', 2);
                var busName = parts[0];
                var proxy = _connection.CreateProxy<IStatusNotifierItem>(busName, new ObjectPath(item.ObjectPath));
                await proxy.ActivateAsync(0, 0);
            }
            catch { }
        }

        public async Task SecondaryActivateItemAsync(TrayItem item)
        {
            try
            {
                var parts = item.ServiceName.Split('/', 2);
                var busName = parts[0];
                var proxy = _connection.CreateProxy<IStatusNotifierItem>(busName, new ObjectPath(item.ObjectPath));
                await proxy.SecondaryActivateAsync(0, 0);
            }
            catch { }
        }

        public void Dispose()
        {
            foreach (var w in _watches)
                w.Dispose();
            _watches.Clear();
        }
    }
}
