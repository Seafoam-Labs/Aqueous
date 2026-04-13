using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Gtk;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class HdrPage
    {
        private static readonly string[] IncompatiblePlugins =
            ["wobbly", "blur", "cube", "fire", "annotate"];

        private static readonly string EnvironmentDirPath =
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".config", "environment.d");

        private static readonly string HdrEnvFilePath =
            Path.Combine(EnvironmentDirPath, "hdr.conf");

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
                var config = WayfireConfigService.Instance;

                if (store.Data.HdrEnabled)
                    EnableHdr(config, store);
                else
                    DisableHdr(config, store);

                // No separate save needed — SettingsWindow.Save() will call config.Save()
                store.NotifyChanged();
            }
            catch
            {
                // Ignore wayfire.ini errors
            }
        }

        private static void EnableHdr(WayfireConfigService config, SettingsStore store)
        {
            // Backup current state
            var plugins = config.GetString("core", "plugins");
            store.Data.PreHdrPluginList = plugins;
            store.Data.PreHdrOpenAnimation = config.GetString("animate", "open_animation");
            store.Data.PreHdrCloseAnimation = config.GetString("animate", "close_animation");

            // Set WLR_RENDERER=vulkan via environment.d
            SetVulkanRenderer(true);

            // Add vk-color-management to plugins
            if (!plugins.Contains("vk-color-management"))
                plugins = plugins.TrimEnd() + " vk-color-management";

            // Remove incompatible plugins
            if (store.Data.HdrDisableIncompatibleAnimations)
            {
                var pluginList = plugins.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
                foreach (var p in IncompatiblePlugins)
                    pluginList.Remove(p);
                plugins = string.Join(" ", pluginList);
            }

            config.SetString("core", "plugins", plugins);

            // Configure vk-color-management section
            config.SetString("vk-color-management", "hdr", "true");

            // Set safe animation defaults
            if (store.Data.HdrDisableIncompatibleAnimations)
            {
                config.SetString("animate", "open_animation", "zoom");
                config.SetString("animate", "close_animation", "zoom");
                config.SetString("animate", "fire_enabled_for", "none");
            }
        }

        private static void DisableHdr(WayfireConfigService config, SettingsStore store)
        {
            // Remove WLR_RENDERER=vulkan
            SetVulkanRenderer(false);

            // Restore plugins
            if (store.Data.PreHdrPluginList != null)
                config.SetString("core", "plugins", store.Data.PreHdrPluginList);
            else
            {
                var plugins = config.GetString("core", "plugins");
                var pluginList = plugins.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
                pluginList.Remove("vk-color-management");
                config.SetString("core", "plugins", string.Join(" ", pluginList));
            }

            // Remove vk-color-management config
            config.RemoveKey("vk-color-management", "hdr");

            // Restore animations
            if (store.Data.PreHdrOpenAnimation != null)
                config.SetString("animate", "open_animation", store.Data.PreHdrOpenAnimation);
            if (store.Data.PreHdrCloseAnimation != null)
                config.SetString("animate", "close_animation", store.Data.PreHdrCloseAnimation);

            // Clear backup
            store.Data.PreHdrPluginList = null;
            store.Data.PreHdrOpenAnimation = null;
            store.Data.PreHdrCloseAnimation = null;
        }

        private static void SetVulkanRenderer(bool enable)
        {
            if (enable)
            {
                Directory.CreateDirectory(EnvironmentDirPath);
                File.WriteAllText(HdrEnvFilePath, "WLR_RENDERER=vulkan\n");
            }
            else
            {
                if (File.Exists(HdrEnvFilePath))
                    File.Delete(HdrEnvFilePath);
            }
        }
    }
}
