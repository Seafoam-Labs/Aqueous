using System;
using System.Collections.Generic;
using System.Linq;
using Gtk;
using static Aqueous.Features.Settings.SettingsWidgets;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class WindowRulesPage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            var headerBox = Gtk.Box.New(Orientation.Horizontal, 8);
            headerBox.Append(SectionTitle("Window Rules"));
            
            var addBtn = Gtk.Button.NewWithLabel("Add Advanced Rule...");
            addBtn.AddCssClass("settings-button");
            addBtn.SetValign(Align.Center);
            addBtn.SetHexpand(true);
            addBtn.SetHalign(Align.End);
            addBtn.OnClicked += (s, e) =>
            {
                var dialog = new WindowRuleEditDialog((Gtk.Window)page.GetRoot(), "", "", () => 
                {
                    // Refresh or let user know
                });
                dialog.Present();
            };
            headerBox.Append(addBtn);
            
            page.Append(headerBox);

            // Pin view
            page.Append(SubSectionTitle("Pin View"));
            page.Append(Keybind("Pin to all workspaces", "pin-view", "pin", "none"));

            // Ghost
            page.Append(SubSectionTitle("Ghost Windows"));
            page.Append(Entry("Ghost match", "ghost", "ghost_match"));
            page.Append(Keybind("Ghost toggle", "ghost", "ghost_toggle", "none"));

            // All Rules
            page.Append(SubSectionTitle("Configured Rules"));
            var rulesBox = CreateAllRulesBox(page);
            page.Append(rulesBox);

            // Force fullscreen
            page.Append(SubSectionTitle("Force Fullscreen"));
            page.Append(Keybind("Toggle", "force-fullscreen", "key_toggle_fullscreen", "<alt> <super> KEY_F"));
            page.Append(Toggle("Preserve aspect", "force-fullscreen", "preserve_aspect", true));
            page.Append(Toggle("Constrain pointer", "force-fullscreen", "constrain_pointer"));
            page.Append(Toggle("Transparent behind", "force-fullscreen", "transparent_behind_views", true));

            // Decoration forced/ignored views
            page.Append(SubSectionTitle("Decoration View Filters"));
            page.Append(Entry("Forced decoration views", "decoration", "forced_views", "none"));
            page.Append(Entry("Ignored decoration views", "decoration", "ignore_views", "none"));

            // Shortcuts inhibit
            page.Append(SubSectionTitle("Shortcuts Inhibit"));
            page.Append(Keybind("Break grab", "shortcuts-inhibit", "break_grab", "none"));
            page.Append(Entry("Ignore views", "shortcuts-inhibit", "ignore_views", "none"));
            page.Append(Entry("Inhibit by default", "shortcuts-inhibit", "inhibit_by_default", "none"));

            return page;
        }

        private static Gtk.Box CreateAllRulesBox(Gtk.Box parentPage)
        {
            var container = Gtk.Box.New(Orientation.Vertical, 8);
            var rulesListContainer = Gtk.Box.New(Orientation.Vertical, 4);
            container.Append(rulesListContainer);

            void RenderRules()
            {
                while (rulesListContainer.GetFirstChild() != null)
                {
                    rulesListContainer.Remove(rulesListContainer.GetFirstChild()!);
                }

                var wayfire = WayfireConfigService.Instance;
                var windowRules = wayfire.GetSectionKeys("window-rules");

                foreach (var kvp in windowRules)
                {
                    var ruleKey = kvp.Key;
                    var ruleValue = kvp.Value;

                    var row = Gtk.Box.New(Orientation.Horizontal, 8);
                    row.AddCssClass("settings-row");

                    var label = new Gtk.Label { Label_ = $"{ruleKey}: {ruleValue}", Xalign = 0, Hexpand = true };
                    label.SetEllipsize(Pango.EllipsizeMode.End);
                    row.Append(label);

                    var editBtn = Gtk.Button.NewFromIconName("document-edit-symbolic");
                    editBtn.AddCssClass("settings-button");
                    editBtn.OnClicked += (s, e) =>
                    {
                        var dialog = new WindowRuleEditDialog((Gtk.Window)parentPage.GetRoot(), ruleKey, ruleValue, () => RenderRules());
                        dialog.Present();
                    };
                    row.Append(editBtn);

                    var removeBtn = Gtk.Button.NewFromIconName("user-trash-symbolic");
                    removeBtn.AddCssClass("settings-button");
                    removeBtn.OnClicked += (s, e) =>
                    {
                        wayfire.RemoveKey("window-rules", ruleKey);
                        RenderRules();
                    };
                    row.Append(removeBtn);

                    rulesListContainer.Append(row);
                }
            }

            RenderRules();
            return container;
        }
    }
}
