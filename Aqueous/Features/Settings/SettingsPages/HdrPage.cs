using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Gtk;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class HdrPage
    {
        private static readonly string WayfireIniPath =
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".config", "wayfire.ini");

        private static readonly string[] IncompatiblePlugins =
            ["wobbly", "blur", "cube", "fire", "annotate"];

        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            var title = Gtk.Label.New("Display / HDR");
            title.AddCssClass("settings-section-title");
            title.Halign = Align.Start;
            page.Append(title);

            page.Append(CreateHdrToggleRow(store));
            page.Append(CreateDisableAnimationsRow(store));
            page.Append(CreateInfoSection());
            page.Append(CreateApplyButton(store));

            return page;
        }

        private static Gtk.Box CreateHdrToggleRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Enable HDR (Vulkan renderer)");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            var toggle = Gtk.Switch.New();
            toggle.Active = store.Data.HdrEnabled;
            toggle.Valign = Align.Center;
            toggle.OnStateSet += (sender, args) =>
            {
                store.Data.HdrEnabled = args.State;
                return false;
            };
            row.Append(toggle);

            return row;
        }

        private static Gtk.Box CreateDisableAnimationsRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Disable incompatible animations");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            var subLabel = Gtk.Label.New("Wobbly, Blur, Cube, Fire, Annotate");
            subLabel.AddCssClass("hdr-info");
            subLabel.Halign = Align.Start;

            var toggle = Gtk.Switch.New();
            toggle.Active = store.Data.HdrDisableIncompatibleAnimations;
            toggle.Valign = Align.Center;
            toggle.OnStateSet += (sender, args) =>
            {
                store.Data.HdrDisableIncompatibleAnimations = args.State;
                return false;
            };
            row.Append(toggle);

            var container = Gtk.Box.New(Orientation.Vertical, 4);
            container.Append(row);
            container.Append(subLabel);
            return container;
        }

        private static Gtk.Box CreateInfoSection()
        {
            var box = Gtk.Box.New(Orientation.Vertical, 4);
            box.MarginTop = 12;

            var warning = Gtk.Label.New("⚠ Enabling HDR switches to the Vulkan renderer. Some visual plugins (blur, wobbly, cube) will be disabled as they require OpenGL.");
            warning.AddCssClass("hdr-warning");
            warning.Halign = Align.Start;
            warning.Wrap = true;
            box.Append(warning);

            var info = Gtk.Label.New("A session restart is required for changes to take effect.");
            info.AddCssClass("hdr-info");
            info.Halign = Align.Start;
            box.Append(info);

            return box;
        }

        private static Gtk.Box CreateApplyButton(SettingsStore store)
        {
            var box = Gtk.Box.New(Orientation.Horizontal, 0);
            box.MarginTop = 16;

            var btn = Gtk.Button.NewWithLabel("Apply HDR Settings");
            btn.AddCssClass("settings-save-btn");
            btn.OnClicked += (_, _) =>
            {
                ApplyHdrSettings(store);
            };
            box.Append(btn);

            return box;
        }

        private static void ApplyHdrSettings(SettingsStore store)
        {
            try
            {
                if (!File.Exists(WayfireIniPath))
                    return;

                var lines = new List<string>(File.ReadAllLines(WayfireIniPath));

                if (store.Data.HdrEnabled)
                    EnableHdr(lines, store);
                else
                    DisableHdr(lines, store);

                File.WriteAllLines(WayfireIniPath, lines);
                store.NotifyChanged();
            }
            catch
            {
                // Ignore wayfire.ini errors
            }
        }

        private static void EnableHdr(List<string> lines, SettingsStore store)
        {
            // Backup current state
            var pluginLine = FindKeyInSection(lines, "core", "plugins");
            if (pluginLine >= 0)
                store.Data.PreHdrPluginList = GetValue(lines[pluginLine]);

            var openAnim = FindKeyInSection(lines, "animate", "open_animation");
            if (openAnim >= 0)
                store.Data.PreHdrOpenAnimation = GetValue(lines[openAnim]);

            var closeAnim = FindKeyInSection(lines, "animate", "close_animation");
            if (closeAnim >= 0)
                store.Data.PreHdrCloseAnimation = GetValue(lines[closeAnim]);

            // Add WLR_RENDERER=vulkan to [autostart]
            var autostartEnv = FindKeyInSection(lines, "autostart", "env_hdr_renderer");
            if (autostartEnv >= 0)
                lines[autostartEnv] = "env_hdr_renderer = WLR_RENDERER=vulkan";
            else
                InsertInSection(lines, "autostart", "env_hdr_renderer = WLR_RENDERER=vulkan");

            // Add vk-color-management to plugins
            if (pluginLine >= 0)
            {
                var plugins = GetValue(lines[pluginLine]);
                if (!plugins.Contains("vk-color-management"))
                {
                    plugins = plugins.TrimEnd() + " vk-color-management";
                    lines[pluginLine] = "plugins = " + plugins;
                }

                // Remove incompatible plugins
                if (store.Data.HdrDisableIncompatibleAnimations)
                {
                    var pluginList = plugins.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
                    foreach (var p in IncompatiblePlugins)
                        pluginList.Remove(p);
                    lines[pluginLine] = "plugins = " + string.Join(" ", pluginList);
                }
            }

            // Set safe animation defaults
            if (store.Data.HdrDisableIncompatibleAnimations)
            {
                SetKeyInSection(lines, "animate", "open_animation", "zoom");
                SetKeyInSection(lines, "animate", "close_animation", "zoom");
                SetKeyInSection(lines, "animate", "fire_enabled_for", "none");
            }
        }

        private static void DisableHdr(List<string> lines, SettingsStore store)
        {
            // Remove WLR_RENDERER=vulkan from [autostart]
            var autostartEnv = FindKeyInSection(lines, "autostart", "env_hdr_renderer");
            if (autostartEnv >= 0)
                lines.RemoveAt(autostartEnv);

            // Restore plugins
            var pluginLine = FindKeyInSection(lines, "core", "plugins");
            if (pluginLine >= 0)
            {
                if (store.Data.PreHdrPluginList != null)
                    lines[pluginLine] = "plugins = " + store.Data.PreHdrPluginList;
                else
                {
                    // Just remove vk-color-management
                    var plugins = GetValue(lines[pluginLine]);
                    var pluginList = plugins.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
                    pluginList.Remove("vk-color-management");
                    lines[pluginLine] = "plugins = " + string.Join(" ", pluginList);
                }
            }

            // Restore animations
            if (store.Data.PreHdrOpenAnimation != null)
                SetKeyInSection(lines, "animate", "open_animation", store.Data.PreHdrOpenAnimation);
            if (store.Data.PreHdrCloseAnimation != null)
                SetKeyInSection(lines, "animate", "close_animation", store.Data.PreHdrCloseAnimation);

            // Clear backup
            store.Data.PreHdrPluginList = null;
            store.Data.PreHdrOpenAnimation = null;
            store.Data.PreHdrCloseAnimation = null;
        }

        private static int FindSectionStart(List<string> lines, string section)
        {
            for (int i = 0; i < lines.Count; i++)
            {
                if (lines[i].Trim() == $"[{section}]")
                    return i;
            }
            return -1;
        }

        private static int FindKeyInSection(List<string> lines, string section, string key)
        {
            int sectionStart = FindSectionStart(lines, section);
            if (sectionStart < 0) return -1;

            for (int i = sectionStart + 1; i < lines.Count; i++)
            {
                var trimmed = lines[i].Trim();
                if (trimmed.StartsWith('[') && trimmed.EndsWith(']'))
                    break;
                if (trimmed.StartsWith(key + " =") || trimmed.StartsWith(key + "="))
                    return i;
            }
            return -1;
        }

        private static string GetValue(string line)
        {
            var idx = line.IndexOf('=');
            return idx >= 0 ? line.Substring(idx + 1).Trim() : "";
        }

        private static void SetKeyInSection(List<string> lines, string section, string key, string value)
        {
            var idx = FindKeyInSection(lines, section, key);
            if (idx >= 0)
                lines[idx] = $"{key} = {value}";
            else
                InsertInSection(lines, section, $"{key} = {value}");
        }

        private static void InsertInSection(List<string> lines, string section, string entry)
        {
            int sectionStart = FindSectionStart(lines, section);
            if (sectionStart < 0)
            {
                lines.Add($"[{section}]");
                lines.Add(entry);
                return;
            }

            // Insert after last key in section
            int insertAt = sectionStart + 1;
            for (int i = sectionStart + 1; i < lines.Count; i++)
            {
                var trimmed = lines[i].Trim();
                if (trimmed.StartsWith('[') && trimmed.EndsWith(']'))
                    break;
                insertAt = i + 1;
            }
            lines.Insert(insertAt, entry);
        }
    }
}
