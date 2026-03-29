using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace Aqueous.Features.SnapTo
{
    public record Zone(string Name, double X, double Y, double Width, double Height);

    public record ZoneLayout(string Name, List<Zone> Zones);

    public static class SnapToConfig
    {
        private static readonly string ConfigPath =
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".config", "aqueous", "snapto.json");

        public static List<ZoneLayout> Load()
        {
            if (!File.Exists(ConfigPath)) return [GetDefault()];
            var json = File.ReadAllText(ConfigPath);
            return JsonSerializer.Deserialize(json, SnapToJsonContext.Default.ListZoneLayout) ?? [GetDefault()];
        }

        public static ZoneLayout GetDefault() => new("Halves",
        [
            new("Left", 0, 0, 0.5, 1.0),
            new("Right", 0.5, 0, 0.5, 1.0)
        ]);
    }
}
