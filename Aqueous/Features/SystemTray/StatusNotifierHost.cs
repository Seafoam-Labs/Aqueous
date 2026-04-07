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

    // For reading properties via org.freedesktop.DBus.Properties
    [DBusInterface("org.freedesktop.DBus.Properties")]
    public interface ISNIProperties : IDBusObject
    {
        Task<IDictionary<string, object>> GetAllAsync(string interfaceName);
        Task<object> GetAsync(string interfaceName, string property);
    }

    public class StatusNotifierHost : IDisposable
    {
        private readonly Connection _connection;
        private readonly StatusNotifierWatcher? _localWatcher;
        private readonly DBusMenuProxy _menuProxy;
        private readonly Dictionary<string, TrayItem> _items = new();
        private readonly List<IDisposable> _watches = new();

        public event Action? ItemsChanged;
        public IReadOnlyList<TrayItem> Items => _items.Values.ToList();
        public DBusMenuProxy MenuProxy => _menuProxy;

        public StatusNotifierHost(Connection connection, StatusNotifierWatcher? localWatcher)
        {
            _connection = connection;
            _localWatcher = localWatcher;
            _menuProxy = new DBusMenuProxy(connection);
        }

        public async Task StartAsync()
        {
            // Watch for D-Bus name owner changes to detect app exits
            var dbus = _connection.CreateProxy<IDBus>("org.freedesktop.DBus", new ObjectPath("/org/freedesktop/DBus"));
            var nameWatch = await dbus.WatchNameOwnerChangedAsync(change =>
            {
                if (string.IsNullOrEmpty(change.newOwner))
                {
                    var toRemove = _items.Keys
                        .Where(k => k == change.name || k.StartsWith(change.name + "/"))
                        .ToList();
                    foreach (var key in toRemove)
                    {
                        if (_localWatcher != null)
                            _localWatcher.RemoveItem(key);
                        else
                            OnItemUnregistered(key);
                    }
                }
            });
            _watches.Add(nameWatch);

            if (_localWatcher != null)
            {
                // Local watcher mode — use in-process events
                _localWatcher.ItemRegistered += OnItemRegistered;
                _localWatcher.ItemUnregistered += OnItemUnregistered;

                foreach (var service in _localWatcher.RegisteredItems)
                    OnItemRegistered(service);
            }
            else
            {
                // Remote watcher mode — use D-Bus proxy
                var remoteWatcher = _connection.CreateProxy<IStatusNotifierWatcher>(
                    "org.kde.StatusNotifierWatcher",
                    new ObjectPath("/StatusNotifierWatcher"));

                // Watch for new items registered
                var regWatch = await remoteWatcher.WatchStatusNotifierItemRegisteredAsync(
                    service =>
                    {
                        Console.Error.WriteLine($"[SystemTray] Remote item registered: {service}");
                        OnItemRegistered(service);
                    },
                    ex => Console.Error.WriteLine($"[SystemTray] Watch registered error: {ex.Message}"));
                _watches.Add(regWatch);

                // Watch for items unregistered
                var unregWatch = await remoteWatcher.WatchStatusNotifierItemUnregisteredAsync(
                    service =>
                    {
                        Console.Error.WriteLine($"[SystemTray] Remote item unregistered: {service}");
                        OnItemUnregistered(service);
                    },
                    ex => Console.Error.WriteLine($"[SystemTray] Watch unregistered error: {ex.Message}"));
                _watches.Add(unregWatch);

                // Enumerate pre-existing items from the remote watcher
                try
                {
                    var existingItems = await remoteWatcher.GetAsync<string[]>("RegisteredStatusNotifierItems");
                    Console.Error.WriteLine($"[SystemTray] Found {existingItems.Length} existing items");
                    foreach (var service in existingItems)
                        OnItemRegistered(service);
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"[SystemTray] Failed to get existing items: {ex.Message}");
                }
            }
        }

        private void OnItemRegistered(string service)
        {
            if (_items.ContainsKey(service))
                return;

            var item = new TrayItem { ServiceName = service };

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
                    Console.Error.WriteLine($"[SystemTray] Loaded item: {item.Id} ({item.IconName}) from {busName}");
                    GLib.Functions.IdleAdd(0, () => { ItemsChanged?.Invoke(); return false; });
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"[SystemTray] Failed to load item {service}: {ex.Message}");
                }
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
            // Use org.freedesktop.DBus.Properties.GetAll instead of the SNI GetAll
            var propsProxy = _connection.CreateProxy<ISNIProperties>(busName, new ObjectPath(item.ObjectPath));
            try
            {
                var props = await propsProxy.GetAllAsync("org.kde.StatusNotifierItem");
                if (props.TryGetValue("Id", out var id)) item.Id = id as string ?? "";
                if (props.TryGetValue("Title", out var title)) item.Title = title as string ?? "";
                if (props.TryGetValue("Status", out var status)) item.Status = status as string ?? "Active";
                if (props.TryGetValue("Category", out var cat)) item.Category = cat as string ?? "";
                if (props.TryGetValue("IconName", out var iconName)) item.IconName = iconName as string ?? "";
                if (props.TryGetValue("IconThemePath", out var themePath) && themePath is string tp && !string.IsNullOrEmpty(tp))
                {
                    var theme = Gtk.IconTheme.GetForDisplay(Gdk.Display.GetDefault()!);
                    theme.AddSearchPath(tp);
                }
                if (props.TryGetValue("Menu", out var menu) && menu is ObjectPath menuPath)
                    item.MenuPath = menuPath.ToString();
                else if (props.TryGetValue("Menu", out var menuStr) && menuStr is string ms)
                    item.MenuPath = ms;

                // Try to get ToolTip
                if (props.TryGetValue("ToolTip", out var tooltip))
                {
                    if (tooltip is string ttStr)
                        item.ToolTipTitle = ttStr;
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[SystemTray] Properties.GetAll failed for {busName}: {ex.Message}");

                // Fallback: try reading individual properties via the SNI interface
                try
                {
                    var sniProxy = _connection.CreateProxy<IStatusNotifierItem>(busName, new ObjectPath(item.ObjectPath));
                    var fallbackProps = await sniProxy.GetAllAsync();
                    if (fallbackProps.TryGetValue("Id", out var id)) item.Id = id as string ?? "";
                    if (fallbackProps.TryGetValue("Title", out var title)) item.Title = title as string ?? "";
                    if (fallbackProps.TryGetValue("Status", out var status)) item.Status = status as string ?? "Active";
                    if (fallbackProps.TryGetValue("IconName", out var iconName)) item.IconName = iconName as string ?? "";
                    if (fallbackProps.TryGetValue("Menu", out var menu) && menu is ObjectPath menuPath)
                        item.MenuPath = menuPath.ToString();
                }
                catch (Exception ex2)
                {
                    Console.Error.WriteLine($"[SystemTray] Fallback GetAll also failed for {busName}: {ex2.Message}");
                }
            }
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
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[SystemTray] Failed to watch signals for {busName}: {ex.Message}");
            }
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
