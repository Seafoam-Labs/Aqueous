using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Tmds.DBus.Protocol;

namespace Aqueous.Features.SystemTray
{
    public class DBusMenuProxy
    {
        private readonly DBusConnection _connection;

        public DBusMenuProxy(DBusConnection connection)
        {
            _connection = connection;
        }

        public async Task<List<MenuItem>> GetMenuItemsAsync(string serviceName, string menuPath)
        {
            var items = new List<MenuItem>();
            try
            {
                // Call com.canonical.dbusmenu.GetLayout(parentId=0, recursionDepth=-1, propertyNames=[])
                var writer = _connection.GetMessageWriter();
                writer.WriteMethodCallHeader(
                    destination: serviceName,
                    path: menuPath,
                    @interface: "com.canonical.dbusmenu",
                    signature: "iias",
                    member: "GetLayout");
                writer.WriteInt32(0);       // parentId
                writer.WriteInt32(-1);      // recursionDepth
                var arrayStart = writer.WriteArrayStart(DBusType.String);
                writer.WriteArrayEnd(arrayStart); // empty string array

                var layout = await _connection.CallMethodAsync(
                    writer.CreateMessage(),
                    static (Message message, object? state) =>
                    {
                        var reader = message.GetBodyReader();
                        var _revision = reader.ReadUInt32();
                        // Read the root layout struct (ia{sv}av)
                        return ReadLayoutStruct(ref reader);
                    });

                // Parse children of root
                if (layout.Children != null)
                    ParseChildren(layout.Children, items);
            }
            catch { }
            return items;
        }

        private static LayoutNode ReadLayoutStruct(ref Reader reader)
        {
            reader.AlignStruct();
            var id = reader.ReadInt32();

            // Read properties dict a{sv}
            var props = new Dictionary<string, VariantValue>();
            var dictEnd = reader.ReadArrayStart(DBusType.DictEntry);
            while (reader.HasNext(dictEnd))
            {
                reader.AlignStruct();
                var key = reader.ReadString();
                var value = reader.ReadVariantValue();
                props[key] = value;
            }

            // Read children av (array of variants, each containing a struct)
            var children = new List<LayoutNode>();
            var childArrayEnd = reader.ReadArrayStart(DBusType.Variant);
            while (reader.HasNext(childArrayEnd))
            {
                // Each child is a variant containing a struct (ia{sv}av)
                reader.ReadSignature("(ia{sv}av)");
                var child = ReadLayoutStruct(ref reader);
                children.Add(child);
            }

            return new LayoutNode { Id = id, Properties = props, Children = children };
        }

        private void ParseChildren(List<LayoutNode> children, List<MenuItem> items)
        {
            foreach (var child in children)
            {
                var label = "";
                var type = "";
                var enabled = true;
                var visible = true;

                if (child.Properties.TryGetValue("label", out var l))
                    try { label = l.GetString(); } catch { }
                if (child.Properties.TryGetValue("type", out var t))
                    try { type = t.GetString(); } catch { }
                if (child.Properties.TryGetValue("enabled", out var e))
                    try { enabled = e.GetBool(); } catch { }
                if (child.Properties.TryGetValue("visible", out var v))
                    try { visible = v.GetBool(); } catch { }

                var item = new MenuItem
                {
                    Id = child.Id,
                    Label = label,
                    Type = type,
                    Enabled = enabled,
                    Visible = visible
                };

                if (child.Children is { Count: > 0 })
                    ParseChildren(child.Children, item.Children);

                items.Add(item);
            }
        }

        public async Task ActivateMenuItemAsync(string serviceName, string menuPath, int itemId)
        {
            try
            {
                // Call com.canonical.dbusmenu.Event(id, eventId, data, timestamp)
                var writer = _connection.GetMessageWriter();
                writer.WriteMethodCallHeader(
                    destination: serviceName,
                    path: menuPath,
                    @interface: "com.canonical.dbusmenu",
                    signature: "isvu",
                    member: "Event");
                writer.WriteInt32(itemId);
                writer.WriteString("clicked");
                writer.WriteVariant(VariantValue.Int32(0));
                writer.WriteUInt32(0);
                await _connection.CallMethodAsync(writer.CreateMessage());
            }
            catch { }
        }

        private class LayoutNode
        {
            public int Id { get; set; }
            public Dictionary<string, VariantValue> Properties { get; set; } = new();
            public List<LayoutNode>? Children { get; set; }
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
