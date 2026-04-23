using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace Aqueous.Features.SnapTo
{
    /// <summary>How River should realise a zone when the user snaps to it.</summary>
    public enum RiverSnapAction
    {
        /// <summary>Switch focused tag(s); the dynamic tiler re-lays out the view.</summary>
        Tile = 0,
        /// <summary>Mark the view floating and place it at the zone geometry (needs ForeignToplevel).</summary>
        Float = 1,
    }

    public record Zone(string Name, double X, double Y, double Width, double Height)
    {
        /// <summary>
        /// Optional River tag bitmask (bit i = tag i+1). When null, <see cref="SnapToConfig.Load"/>
        /// assigns a default based on zone order on River sessions.
        /// </summary>
        public uint? RiverTagMask { get; set; }

        /// <summary>River-only behaviour hint; ignored on Wayfire.</summary>
        public RiverSnapAction RiverAction { get; set; } = RiverSnapAction.Tile;
    }

    public record ZoneLayout(string Name, List<Zone> Zones);

    public static class SnapToConfig
    {
        private static readonly string ConfigPath =
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".config", "aqueous", "snapto.json");

        public static List<ZoneLayout> Load()
        {
            List<ZoneLayout> layouts;
            if (!File.Exists(ConfigPath))
            {
                layouts = GetDefaults();
            }
            else
            {
                var json = File.ReadAllText(ConfigPath);
                layouts = JsonSerializer.Deserialize(json, SnapToJsonContext.Default.ListZoneLayout) ?? GetDefaults();
            }

            AssignDefaultRiverTagMasks(layouts);
            return layouts;
        }

        /// <summary>
        /// Fill in <see cref="Zone.RiverTagMask"/> for any zone missing one.
        /// Zones are mapped to tags 1..9 in declaration order (top-left → bottom-right
        /// for the default grid), wrapping within the 9 River default tags. Beyond 9
        /// zones we continue bit-shifting up to bit 30 to avoid sign-bit collisions.
        /// </summary>
        public static void AssignDefaultRiverTagMasks(List<ZoneLayout> layouts)
        {
            foreach (var layout in layouts)
            {
                for (int i = 0; i < layout.Zones.Count; i++)
                {
                    var z = layout.Zones[i];
                    if (z.RiverTagMask is null)
                    {
                        int bit = Math.Min(i, 30);
                        z.RiverTagMask = 1u << bit;
                    }
                }
            }
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
