using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Tmds.DBus.Protocol;

namespace Aqueous.Features.SystemTray
{
    public class StatusNotifierHost : IDisposable
    {
        private readonly DBusConnection _connection;
        private readonly StatusNotifierWatcher? _localWatcher;
        private readonly DBusMenuProxy _menuProxy;
        private readonly Dictionary<string, TrayItem> _items = new();
        private readonly List<IDisposable> _watches = new();

        public event Action? ItemsChanged;
        public IReadOnlyList<TrayItem> Items => _items.Values.ToList();
        public DBusMenuProxy MenuProxy => _menuProxy;

        public StatusNotifierHost(DBusConnection connection, StatusNotifierWatcher? localWatcher)
        {
            _connection = connection;
            _localWatcher = localWatcher;
            _menuProxy = new DBusMenuProxy(connection);
        }

        public async Task StartAsync()
        {
            // Watch for D-Bus name owner changes to detect app exits
            var nameWatch = await _connection.WatchSignalAsync(
                sender: "org.freedesktop.DBus",
                path: "/org/freedesktop/DBus",
                @interface: "org.freedesktop.DBus",
                signal: "NameOwnerChanged",
                static (Message message, object? state) =>
                {
                    var reader = message.GetBodyReader();
                    var name = reader.ReadString();
                    var oldOwner = reader.ReadString();
                    var newOwner = reader.ReadString();
                    return (name, oldOwner, newOwner);
                },
                (Exception? ex, (string name, string oldOwner, string newOwner) change) =>
                {
                    if (ex is null && string.IsNullOrEmpty(change.newOwner))
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
                },
                readerState: null,
                emitOnCapturedContext: false,
                flags: ObserverFlags.None);
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
                // Remote watcher mode — watch D-Bus signals
                var regWatch = await _connection.WatchSignalAsync(
                    sender: "org.kde.StatusNotifierWatcher",
                    path: "/StatusNotifierWatcher",
                    @interface: "org.kde.StatusNotifierWatcher",
                    signal: "StatusNotifierItemRegistered",
                    static (Message message, object? state) =>
                    {
                        var reader = message.GetBodyReader();
                        return reader.ReadString();
                    },
                    (Exception? ex, string service) =>
                    {
                        if (ex is null)
                        {
                            Console.Error.WriteLine($"[SystemTray] Remote item registered: {service}");
                            OnItemRegistered(service);
                        }
                    },
                    readerState: null,
                    emitOnCapturedContext: false,
                    flags: ObserverFlags.None);
                _watches.Add(regWatch);

                var unregWatch = await _connection.WatchSignalAsync(
                    sender: "org.kde.StatusNotifierWatcher",
                    path: "/StatusNotifierWatcher",
                    @interface: "org.kde.StatusNotifierWatcher",
                    signal: "StatusNotifierItemUnregistered",
                    static (Message message, object? state) =>
                    {
                        var reader = message.GetBodyReader();
                        return reader.ReadString();
                    },
                    (Exception? ex, string service) =>
                    {
                        if (ex is null)
                        {
                            Console.Error.WriteLine($"[SystemTray] Remote item unregistered: {service}");
                            OnItemUnregistered(service);
                        }
                    },
                    readerState: null,
                    emitOnCapturedContext: false,
                    flags: ObserverFlags.None);
                _watches.Add(unregWatch);

                // Enumerate pre-existing items from the remote watcher
                try
                {
                    var val = await DBusHelper.GetPropertyAsync(
                        _connection, "org.kde.StatusNotifierWatcher",
                        "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
                        "RegisteredStatusNotifierItems");
                    var count = val.Count;
                    Console.Error.WriteLine($"[SystemTray] Found {count} existing items");
                    for (int i = 0; i < count; i++)
                        OnItemRegistered(val.GetItem(i).GetString());
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
            Dictionary<string, VariantValue>? props = null;

            // Try kde interface first, then freedesktop
            foreach (var iface in new[] { "org.kde.StatusNotifierItem", "org.freedesktop.StatusNotifierItem" })
            {
                try
                {
                    props = await DBusHelper.GetAllPropertiesAsync(_connection, busName, item.ObjectPath, iface);
                    if (props.Count > 0)
                        break;
                }
                catch
                {
                    // Try next interface
                }
            }

            if (props is null || props.Count == 0)
            {
                Console.Error.WriteLine($"[SystemTray] Properties.GetAll failed for {busName} on both interfaces");
                return;
            }

            if (props.TryGetValue("Id", out var id)) item.Id = id.GetString();
            if (props.TryGetValue("Title", out var title)) item.Title = title.GetString();
            if (props.TryGetValue("Status", out var status)) item.Status = status.GetString();
            if (props.TryGetValue("Category", out var cat)) item.Category = cat.GetString();
            if (props.TryGetValue("IconName", out var iconName)) item.IconName = iconName.GetString();

            if (props.TryGetValue("IconThemePath", out var tp))
            {
                var path = tp.GetString();
                if (!string.IsNullOrEmpty(path))
                    GLib.Functions.IdleAdd(0, () =>
                    {
                        Gtk.IconTheme.GetForDisplay(Gdk.Display.GetDefault()!).AddSearchPath(path);
                        return false;
                    });
            }

            if (props.TryGetValue("IconPixmap", out var pixmap))
            {
                try
                {
                    item.IconPixmap = DeserializeIconPixmap(pixmap);
                }
                catch (Exception pxEx)
                {
                    Console.Error.WriteLine($"[SystemTray] Failed to deserialize IconPixmap: {pxEx.Message}");
                }
            }

            if (props.TryGetValue("Menu", out var menu))
            {
                try
                {
                    item.MenuPath = menu.GetObjectPathAsString();
                }
                catch
                {
                    try { item.MenuPath = menu.GetString(); } catch { }
                }
            }

            // Try to get ToolTip — it's (sa(iiay)ss)
            if (props.TryGetValue("ToolTip", out var tooltip))
            {
                try
                {
                    if (tooltip.Type == VariantValueType.Struct && tooltip.Count >= 4)
                        item.ToolTipTitle = tooltip.GetItem(2).GetString();
                    else if (tooltip.Type == VariantValueType.String)
                        item.ToolTipTitle = tooltip.GetString();
                }
                catch { }
            }
        }

        private async Task WatchItemSignalsAsync(string busName, TrayItem item)
        {
            // Try both interfaces
            foreach (var iface in new[] { "org.kde.StatusNotifierItem", "org.freedesktop.StatusNotifierItem" })
            {
                try
                {
                    var w1 = await _connection.WatchSignalAsync(
                        sender: busName,
                        path: item.ObjectPath,
                        @interface: iface,
                        signal: "NewIcon",
                        (Exception? ex) =>
                        {
                            if (ex is null)
                                Task.Run(async () =>
                                {
                                    await LoadItemPropertiesAsync(busName, item);
                                    GLib.Functions.IdleAdd(0, () => { ItemsChanged?.Invoke(); return false; });
                                });
                        },
                        readerState: null,
                        emitOnCapturedContext: false,
                        flags: ObserverFlags.None);
                    _watches.Add(w1);

                    var w2 = await _connection.WatchSignalAsync(
                        sender: busName,
                        path: item.ObjectPath,
                        @interface: iface,
                        signal: "NewTitle",
                        (Exception? ex) =>
                        {
                            if (ex is null)
                                Task.Run(async () =>
                                {
                                    await LoadItemPropertiesAsync(busName, item);
                                    GLib.Functions.IdleAdd(0, () => { ItemsChanged?.Invoke(); return false; });
                                });
                        },
                        readerState: null,
                        emitOnCapturedContext: false,
                        flags: ObserverFlags.None);
                    _watches.Add(w2);

                    var w3 = await _connection.WatchSignalAsync(
                        sender: busName,
                        path: item.ObjectPath,
                        @interface: iface,
                        signal: "NewStatus",
                        static (Message message, object? state) =>
                        {
                            var reader = message.GetBodyReader();
                            return reader.ReadString();
                        },
                        (Exception? ex, string newStatus) =>
                        {
                            if (ex is null)
                            {
                                item.Status = newStatus;
                                GLib.Functions.IdleAdd(0, () => { ItemsChanged?.Invoke(); return false; });
                            }
                        },
                        readerState: null,
                        emitOnCapturedContext: false,
                        flags: ObserverFlags.None);
                    _watches.Add(w3);

                    return; // Success on this interface
                }
                catch { }
            }

            Console.Error.WriteLine($"[SystemTray] Failed to watch signals for {busName} on both interfaces");
        }

        private static (int Width, int Height, byte[] Data)[]? DeserializeIconPixmap(VariantValue pixmap)
        {
            if (pixmap.Type != VariantValueType.Array || pixmap.Count == 0)
                return null;

            var result = new List<(int, int, byte[])>();
            for (int i = 0; i < pixmap.Count; i++)
            {
                var entry = pixmap.GetItem(i); // struct (iiay)
                var w = entry.GetItem(0).GetInt32();
                var h = entry.GetItem(1).GetInt32();
                var dataVariant = entry.GetItem(2);
                var data = dataVariant.GetArray<byte>();
                result.Add((w, h, data));
            }
            return result.Count > 0 ? result.ToArray() : null;
        }

        public async Task ActivateItemAsync(TrayItem item)
        {
            var parts = item.ServiceName.Split('/', 2);
            var busName = parts[0];
            foreach (var iface in new[] { "org.kde.StatusNotifierItem", "org.freedesktop.StatusNotifierItem" })
            {
                try
                {
                    await DBusHelper.CallMethodIIAsync(_connection, busName, item.ObjectPath, iface, "Activate", 0, 0);
                    return;
                }
                catch { }
            }
        }

        public async Task SecondaryActivateItemAsync(TrayItem item)
        {
            var parts = item.ServiceName.Split('/', 2);
            var busName = parts[0];
            foreach (var iface in new[] { "org.kde.StatusNotifierItem", "org.freedesktop.StatusNotifierItem" })
            {
                try
                {
                    await DBusHelper.CallMethodIIAsync(_connection, busName, item.ObjectPath, iface, "SecondaryActivate", 0, 0);
                    return;
                }
                catch { }
            }
        }

        public void Dispose()
        {
            foreach (var w in _watches)
                w.Dispose();
            _watches.Clear();
        }
    }
}
