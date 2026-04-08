using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Tmds.DBus.Protocol;

namespace Aqueous.Features.SystemTray
{
    public class StatusNotifierWatcher : IPathMethodHandler
    {
        private readonly DBusConnection? _connection;
        private readonly List<string> _items = new();
        private bool _hostRegistered;

        public event Action<string>? ItemRegistered;
        public event Action<string>? ItemUnregistered;

        public IReadOnlyList<string> RegisteredItems => _items;
        public bool IsHostRegistered => _hostRegistered;

        public string Path => "/StatusNotifierWatcher";
        public bool HandlesChildPaths => false;

        private static readonly ReadOnlyMemory<byte> IntrospectXml =
            """
            <interface name="org.kde.StatusNotifierWatcher">
              <method name="RegisterStatusNotifierItem">
                <arg name="service" type="s" direction="in"/>
              </method>
              <method name="RegisterStatusNotifierHost">
                <arg name="service" type="s" direction="in"/>
              </method>
              <signal name="StatusNotifierItemRegistered">
                <arg type="s"/>
              </signal>
              <signal name="StatusNotifierItemUnregistered">
                <arg type="s"/>
              </signal>
              <signal name="StatusNotifierHostRegistered"/>
              <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
              <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
              <property name="ProtocolVersion" type="i" access="read"/>
            </interface>
            """u8.ToArray();

        public StatusNotifierWatcher()
        {
        }

        public StatusNotifierWatcher(DBusConnection connection)
        {
            _connection = connection;
        }

        public ValueTask HandleMethodAsync(MethodContext context)
        {
            if (context.IsDBusIntrospectRequest)
            {
                context.ReplyIntrospectXml([IntrospectXml]);
                return default;
            }

            var request = context.Request;
            var iface = request.InterfaceAsString;
            var member = request.MemberAsString;

            switch (iface)
            {
                case "org.kde.StatusNotifierWatcher":
                    switch (member)
                    {
                        case "RegisterStatusNotifierItem":
                        {
                            var reader = request.GetBodyReader();
                            var service = reader.ReadString();

                            // If the service doesn't contain a bus name, use the sender
                            if (!service.StartsWith(":") && !service.Contains("."))
                                service = request.SenderAsString ?? service;

                            RegisterItem(service);
                            using (var writer = context.CreateReplyWriter(null))
                                context.Reply(writer.CreateMessage());
                            return default;
                        }
                        case "RegisterStatusNotifierHost":
                        {
                            _hostRegistered = true;
                            using (var writer = context.CreateReplyWriter(null))
                                context.Reply(writer.CreateMessage());
                            return default;
                        }
                    }
                    break;

                case "org.freedesktop.DBus.Properties":
                    switch (member)
                    {
                        case "GetAll":
                            HandleGetAll(context);
                            return default;
                        case "Get":
                            HandleGet(context);
                            return default;
                    }
                    break;
            }

            context.ReplyUnknownMethodError();
            return default;
        }

        private void HandleGetAll(MethodContext context)
        {
            using var writer = context.CreateReplyWriter("a{sv}");
            var dictStart = writer.WriteArrayStart(DBusType.DictEntry);

            writer.WriteStructureStart();
            writer.WriteString("RegisteredStatusNotifierItems");
            writer.WriteVariant(VariantValue.Array(_items.ToArray()));

            writer.WriteStructureStart();
            writer.WriteString("IsStatusNotifierHostRegistered");
            writer.WriteVariant(VariantValue.Bool(_hostRegistered));

            writer.WriteStructureStart();
            writer.WriteString("ProtocolVersion");
            writer.WriteVariant(VariantValue.Int32(0));

            writer.WriteArrayEnd(dictStart);
            context.Reply(writer.CreateMessage());
        }

        private void HandleGet(MethodContext context)
        {
            var reader = context.Request.GetBodyReader();
            var _ = reader.ReadString(); // interface
            var prop = reader.ReadString();

            using var writer = context.CreateReplyWriter("v");
            switch (prop)
            {
                case "RegisteredStatusNotifierItems":
                    writer.WriteVariant(VariantValue.Array(_items.ToArray()));
                    break;
                case "IsStatusNotifierHostRegistered":
                    writer.WriteVariant(VariantValue.Bool(_hostRegistered));
                    break;
                case "ProtocolVersion":
                    writer.WriteVariant(VariantValue.Int32(0));
                    break;
                default:
                    context.ReplyError("org.freedesktop.DBus.Error.UnknownProperty", $"Unknown property: {prop}");
                    return;
            }
            context.Reply(writer.CreateMessage());
        }

        private void RegisterItem(string service)
        {
            if (!_items.Contains(service))
            {
                _items.Add(service);
                ItemRegistered?.Invoke(service);

                // Emit D-Bus signal
                if (_connection != null)
                    EmitSignal("StatusNotifierItemRegistered", service);
            }
        }

        public void RemoveItem(string service)
        {
            if (_items.Remove(service))
            {
                ItemUnregistered?.Invoke(service);

                // Emit D-Bus signal
                if (_connection != null)
                    EmitSignal("StatusNotifierItemUnregistered", service);
            }
        }

        public void RegisterHostInternal(string hostName)
        {
            _hostRegistered = true;
        }

        private void EmitSignal(string signalName, string value)
        {
            if (_connection == null) return;
            var writer = _connection.GetMessageWriter();
            writer.WriteSignalHeader(
                destination: null,
                path: "/StatusNotifierWatcher",
                @interface: "org.kde.StatusNotifierWatcher",
                signature: "s",
                member: signalName);
            writer.WriteString(value);
            _connection.TrySendMessage(writer.CreateMessage());
        }
    }
}
