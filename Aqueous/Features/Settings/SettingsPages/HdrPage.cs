using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Gtk;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class HdrPage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            var title = Gtk.Label.New("Display / HDR");
            title.AddCssClass("settings-section-title");
            title.Halign = Align.Start;
            page.Append(title);

            page.Append(CreateHdrToggleRow(store));
            page.Append(CreateIccProfileRow(store));
            page.Append(CreateInfoSection());
            page.Append(CreateApplyButton(store));

            return page;
        }

        private static Gtk.Box CreateHdrToggleRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Enable HDR");
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

        private static Gtk.Box CreateIccProfileRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("ICC Profile Path (optional)");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            var entry = Gtk.Entry.New();
            entry.SetText(store.Data.HdrIccProfilePath ?? "");
            entry.OnChanged += (sender, args) =>
            {
                store.Data.HdrIccProfilePath = entry.GetText();
            };
            row.Append(entry);

            return row;
        }

        private static Gtk.Box CreateInfoSection()
        {
            var box = Gtk.Box.New(Orientation.Vertical, 4);
            box.MarginTop = 12;

            var warning = Gtk.Label.New("⚠ Enabling HDR requires wlroots 0.20 or newer. Color management is handled natively by the compositor core.");
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

                config.Save();
                store.Save();
                store.NotifyChanged();
            }
            catch
            {
                // Ignore wayfire.ini errors
            }
        }

        private static void EnableHdr(WayfireConfigService config, SettingsStore store)
        {
            config.SetString("output:*", "hdr", "true");

            // Write ICC profile if set
            if (!string.IsNullOrWhiteSpace(store.Data.HdrIccProfilePath))
                config.SetString("output:*", "icc_profile", store.Data.HdrIccProfilePath);
        }

        private static void DisableHdr(WayfireConfigService config, SettingsStore store)
        {
            config.SetString("output:*", "hdr", "false");

            // Remove ICC profile config
            config.RemoveKey("output:*", "icc_profile");
        }
    }
}
