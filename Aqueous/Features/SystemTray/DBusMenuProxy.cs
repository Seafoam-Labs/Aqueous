using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Tmds.DBus;

namespace Aqueous.Features.SystemTray
{
    [DBusInterface("com.canonical.dbusmenu")]
    public interface IDBusMenu : IDBusObject
    {
        Task<(uint revision, (int id, IDictionary<string, object> properties, object[] children) layout)> GetLayoutAsync(int parentId, int recursionDepth, string[] propertyNames);
        Task EventAsync(int id, string eventId, object data, uint timestamp);
        Task<IDisposable> WatchLayoutUpdatedAsync(Action<(uint revision, int parent)> handler, Action<Exception>? onError = null);
    }

    public class DBusMenuProxy
    {
        private readonly Connection _connection;

        public DBusMenuProxy(Connection connection)
        {
            _connection = connection;
        }

        public async Task<List<MenuItem>> GetMenuItemsAsync(string serviceName, string menuPath)
        {
            var items = new List<MenuItem>();
            try
            {
                var proxy = _connection.CreateProxy<IDBusMenu>(serviceName, new ObjectPath(menuPath));
                var (_, layout) = await proxy.GetLayoutAsync(0, -1, Array.Empty<string>());
                ParseChildren(layout.children, items);
            }
            catch { }
            return items;
        }

        private void ParseChildren(object[] children, List<MenuItem> items)
        {
            foreach (var child in children)
            {
                if (child is not (int id, IDictionary<string, object> props, object[] subChildren))
                    continue;

                var label = props.TryGetValue("label", out var l) ? l as string ?? "" : "";
                var type = props.TryGetValue("type", out var t) ? t as string ?? "" : "";
                var enabled = !props.TryGetValue("enabled", out var e) || e is not bool eb || eb;
                var visible = !props.TryGetValue("visible", out var v) || v is not bool vb || vb;

                var item = new MenuItem
                {
                    Id = id,
                    Label = label,
                    Type = type,
                    Enabled = enabled,
                    Visible = visible
                };

                if (subChildren.Length > 0)
                    ParseChildren(subChildren, item.Children);

                items.Add(item);
            }
        }

        public async Task ActivateMenuItemAsync(string serviceName, string menuPath, int itemId)
        {
            try
            {
                var proxy = _connection.CreateProxy<IDBusMenu>(serviceName, new ObjectPath(menuPath));
                await proxy.EventAsync(itemId, "clicked", 0, 0);
            }
            catch { }
        }
    }

    public class MenuItem
    {
        public int Id { get; set; }
        public string Label { get; set; } = "";
        public string Type { get; set; } = "";
        public bool Enabled { get; set; } = true;
        public bool Visible { get; set; } = true;
        public List<MenuItem> Children { get; set; } = new();
        public bool IsSeparator => Type == "separator";
    }
}
