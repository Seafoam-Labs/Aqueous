using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Tmds.DBus.Protocol;

namespace Aqueous.Features.SystemTray
{
    internal static class DBusHelper
    {
        /// <summary>
        /// Calls org.freedesktop.DBus.Properties.GetAll(interfaceName) and returns a dictionary of property name → VariantValue.
        /// </summary>
        public static async Task<Dictionary<string, VariantValue>> GetAllPropertiesAsync(
            DBusConnection connection, string busName, string objectPath, string interfaceName)
        {
            var writer = connection.GetMessageWriter();
            writer.WriteMethodCallHeader(
                destination: busName,
                path: objectPath,
                @interface: "org.freedesktop.DBus.Properties",
                signature: "s",
                member: "GetAll");
            writer.WriteString(interfaceName);

            var reply = await connection.CallMethodAsync(
                writer.CreateMessage(),
                static (Message message, object? state) =>
                {
                    var reader = message.GetBodyReader();
                    var dict = new Dictionary<string, VariantValue>();
                    var arrayEnd = reader.ReadArrayStart(DBusType.DictEntry);
                    while (reader.HasNext(arrayEnd))
                    {
                        reader.AlignStruct();
                        var key = reader.ReadString();
                        var value = reader.ReadVariantValue();
                        dict[key] = value;
                    }
                    return dict;
                });
            return reply;
        }

        /// <summary>
        /// Calls a D-Bus method with signature "ii" (e.g., Activate, SecondaryActivate).
        /// </summary>
        public static async Task CallMethodIIAsync(
            DBusConnection connection, string busName, string objectPath,
            string @interface, string member, int x, int y)
        {
            var writer = connection.GetMessageWriter();
            writer.WriteMethodCallHeader(
                destination: busName,
                path: objectPath,
                @interface: @interface,
                signature: "ii",
                member: member);
            writer.WriteInt32(x);
            writer.WriteInt32(y);
            await connection.CallMethodAsync(writer.CreateMessage());
        }

        /// <summary>
        /// Calls a D-Bus method with signature "s" (e.g., RegisterStatusNotifierHost).
        /// </summary>
        public static async Task CallMethodStringAsync(
            DBusConnection connection, string busName, string objectPath,
            string @interface, string member, string value)
        {
            var writer = connection.GetMessageWriter();
            writer.WriteMethodCallHeader(
                destination: busName,
                path: objectPath,
                @interface: @interface,
                signature: "s",
                member: member);
            writer.WriteString(value);
            await connection.CallMethodAsync(writer.CreateMessage());
        }

        /// <summary>
        /// Reads a single property via org.freedesktop.DBus.Properties.Get.
        /// </summary>
        public static async Task<VariantValue> GetPropertyAsync(
            DBusConnection connection, string busName, string objectPath,
            string @interface, string property)
        {
            var writer = connection.GetMessageWriter();
            writer.WriteMethodCallHeader(
                destination: busName,
                path: objectPath,
                @interface: "org.freedesktop.DBus.Properties",
                signature: "ss",
                member: "Get");
            writer.WriteString(@interface);
            writer.WriteString(property);

            return await connection.CallMethodAsync(
                writer.CreateMessage(),
                static (Message message, object? state) =>
                {
                    var reader = message.GetBodyReader();
                    return reader.ReadVariantValue();
                });
        }

        /// <summary>
        /// Requests a well-known bus name via org.freedesktop.DBus.RequestName.
        /// </summary>
        public static async Task RequestNameAsync(DBusConnection connection, string name, uint flags = 0)
        {
            var writer = connection.GetMessageWriter();
            writer.WriteMethodCallHeader(
                destination: "org.freedesktop.DBus",
                path: "/org/freedesktop/DBus",
                @interface: "org.freedesktop.DBus",
                signature: "su",
                member: "RequestName");
            writer.WriteString(name);
            writer.WriteUInt32(flags);
            await connection.CallMethodAsync(writer.CreateMessage());
        }
    }
}
