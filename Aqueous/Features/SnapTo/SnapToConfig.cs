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
            if (!File.Exists(ConfigPath)) return GetDefaults();
            var json = File.ReadAllText(ConfigPath);
            return JsonSerializer.Deserialize(json, SnapToJsonContext.Default.ListZoneLayout) ?? GetDefaults();
        }

        public static void Save(List<ZoneLayout> layouts)
        {
            var dir = Path.GetDirectoryName(ConfigPath)!;
            Directory.CreateDirectory(dir);
            var json = JsonSerializer.Serialize(layouts, SnapToJsonContext.Default.ListZoneLayout);
            File.WriteAllText(ConfigPath, json);
        }

        public static List<ZoneLayout> GetDefaults() =>
        [
            new("Priority Grid",
            [
                new("Top Left", 0, 0, 0.25, 0.5),
                new("Bottom Left 1", 0, 0.5, 0.125, 0.5),
                new("Bottom Left 2", 0.125, 0.5, 0.125, 0.5),
                new("Center", 0.25, 0, 0.5, 1.0),
                new("Right", 0.75, 0, 0.25, 1.0)
            ]),
        ];
    }
}
