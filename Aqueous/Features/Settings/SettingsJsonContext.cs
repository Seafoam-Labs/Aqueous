using System.Text.Json.Serialization;

namespace Aqueous.Features.Settings
{
    [JsonSerializable(typeof(SettingsData))]
    [JsonSourceGenerationOptions(PropertyNameCaseInsensitive = true, WriteIndented = true)]
    internal partial class SettingsJsonContext : JsonSerializerContext
    {
    }
}
