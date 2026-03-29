using System.Text.Json.Serialization;

namespace Aqueous.Features.AudioSwitcher
{
    public class PactlSink
    {
        [JsonPropertyName("index")]
        public int Index { get; set; }

        [JsonPropertyName("name")]
        public string Name { get; set; } = "";

        [JsonPropertyName("description")]
        public string Description { get; set; } = "";

        [JsonPropertyName("state")]
        public string State { get; set; } = "";
    }

    public class PactlSource
    {
        [JsonPropertyName("index")]
        public int Index { get; set; }

        [JsonPropertyName("name")]
        public string Name { get; set; } = "";

        [JsonPropertyName("description")]
        public string Description { get; set; } = "";

        [JsonPropertyName("state")]
        public string State { get; set; } = "";
    }

    public class PactlServerInfo
    {
        [JsonPropertyName("default_sink_name")]
        public string DefaultSinkName { get; set; } = "";

        [JsonPropertyName("default_source_name")]
        public string DefaultSourceName { get; set; } = "";
    }

    [JsonSerializable(typeof(PactlSink[]))]
    [JsonSerializable(typeof(PactlSource[]))]
    [JsonSerializable(typeof(PactlServerInfo))]
    [JsonSourceGenerationOptions(PropertyNameCaseInsensitive = true)]
    internal partial class AudioJsonContext : JsonSerializerContext
    {
    }
}
