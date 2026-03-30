using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace Aqueous.Widgets.StartMenu;

public class StartMenuConfig
{
    private static readonly string ConfigDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        ".config", "aqueous");

    private static readonly string ConfigPath = Path.Combine(ConfigDir, "startmenu.json");

    public List<string> Favorites { get; set; } = new();

    public static StartMenuConfig Load()
    {
        try
        {
            if (File.Exists(ConfigPath))
            {
                var json = File.ReadAllText(ConfigPath);
                return JsonSerializer.Deserialize<StartMenuConfig>(json) ?? new StartMenuConfig();
            }
        }
        catch { }

        return new StartMenuConfig();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(ConfigDir);
            var json = JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(ConfigPath, json);
        }
        catch { }
    }
}
