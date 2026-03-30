using System.Text.Json.Serialization;

namespace Aqueous.Features.Bluetooth
{
    [JsonSerializable(typeof(BluetoothDevice))]
    [JsonSerializable(typeof(BluetoothDevice[]))]
    [JsonSourceGenerationOptions(PropertyNameCaseInsensitive = true, WriteIndented = true)]
    internal partial class BluetoothJsonContext : JsonSerializerContext
    {
    }
}
