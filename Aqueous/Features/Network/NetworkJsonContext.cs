using System.Text.Json.Serialization;
namespace Aqueous.Features.Network
{
    [JsonSerializable(typeof(NetworkDevice))]
    [JsonSerializable(typeof(NetworkDevice[]))]
    [JsonSerializable(typeof(WifiAccessPoint))]
    [JsonSerializable(typeof(WifiAccessPoint[]))]
    [JsonSourceGenerationOptions(PropertyNameCaseInsensitive = true, WriteIndented = true)]
    internal partial class NetworkJsonContext : JsonSerializerContext
    {
    }
}
