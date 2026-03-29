using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Aqueous.Features.SnapTo
{
    [JsonSerializable(typeof(List<ZoneLayout>))]
    [JsonSerializable(typeof(JsonElement[]))]
    [JsonSourceGenerationOptions(PropertyNameCaseInsensitive = true)]
    internal partial class SnapToJsonContext : JsonSerializerContext
    {
    }
}
