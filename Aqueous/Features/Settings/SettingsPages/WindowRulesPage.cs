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

            page.Append(SectionTitle("Window Rules"));

            // Pin view
            page.Append(SubSectionTitle("Pin View"));
            page.Append(Keybind("Pin to all workspaces", "pin-view", "pin", "none"));

            // Ghost
            page.Append(SubSectionTitle("Ghost Windows"));
            page.Append(Entry("Ghost match", "ghost", "ghost_match"));
            page.Append(Keybind("Ghost toggle", "ghost", "ghost_toggle", "none"));

            // Transparency Rules
            page.Append(SubSectionTitle("Transparency Rules"));
            var transparencyBox = CreateTransparencyRulesBox();
            page.Append(transparencyBox);

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

        private class TransparencyRule
        {
            public string OriginalKey { get; set; } = "";
            public string MatchCriteria { get; set; } = "";
            public double Alpha { get; set; } = 1.0;
        }

        private static Gtk.Box CreateTransparencyRulesBox()
        {
            var container = Gtk.Box.New(Orientation.Vertical, 8);
            var rulesListContainer = Gtk.Box.New(Orientation.Vertical, 4);
            container.Append(rulesListContainer);

            var wayfire = WayfireConfigService.Instance;
            var windowRules = wayfire.GetSectionKeys("window-rules");

            var transparencyRules = new List<TransparencyRule>();
            var otherRules = new List<KeyValuePair<string, string>>();

            foreach (var kvp in windowRules)
            {
                var val = kvp.Value.Trim();
                if (val.Contains("set alpha"))
                {
                    // e.g. "on created if app_id is \"alacritty\" then set alpha 0.8"
                    // Extract match criteria and alpha
                    int thenIdx = val.IndexOf(" then ");
                    if (thenIdx > 0 && val.StartsWith("on created if "))
                    {
                        string match = val.Substring(14, thenIdx - 14);
                        int alphaIdx = val.IndexOf("set alpha ", thenIdx);
                        if (alphaIdx > 0)
                        {
                            string alphaStr = val.Substring(alphaIdx + 10).Trim();
                            if (double.TryParse(alphaStr, out double alphaVal))
                            {
                                transparencyRules.Add(new TransparencyRule
                                {
                                    OriginalKey = kvp.Key,
                                    MatchCriteria = match,
                                    Alpha = alphaVal
                                });
                                continue;
                            }
                        }
                    }
                }
                
                otherRules.Add(kvp);
            }

            void SaveRules()
            {
                wayfire.RemoveSection("window-rules");
                int idx = 1;
                
                // Write back other rules
                foreach (var rule in otherRules)
                {
                    wayfire.SetString("window-rules", $"rule_{idx++}", rule.Value);
                }

                // Write transparency rules
                foreach (var rule in transparencyRules)
                {
                    string alphaStr = rule.Alpha.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture);
                    string ruleVal = $"on created if {rule.MatchCriteria} then set alpha {alphaStr}";
                    wayfire.SetString("window-rules", $"rule_{idx++}", ruleVal);
                }
            }

            void RenderRules()
            {
                // Clear existing
                while (rulesListContainer.GetFirstChild() != null)
                {
                    rulesListContainer.Remove(rulesListContainer.GetFirstChild()!);
                }

                for (int i = 0; i < transparencyRules.Count; i++)
                {
                    var rule = transparencyRules[i];
                    int currentIndex = i;
                    var row = CreateRuleWidget(rule, () =>
                    {
                        transparencyRules.RemoveAt(currentIndex);
                        SaveRules();
                        RenderRules();
                    }, () => SaveRules());
                    rulesListContainer.Append(row);
                }
            }

            var addButton = Gtk.Button.NewWithLabel("Add Transparency Rule");
            addButton.AddCssClass("settings-button");
            addButton.OnClicked += (s, e) =>
            {
                transparencyRules.Add(new TransparencyRule
                {
                    MatchCriteria = "app_id is \"unknown\"",
                    Alpha = 0.8
                });
                SaveRules();
                RenderRules();
            };

            container.Append(addButton);
            RenderRules();

            return container;
        }

        private static Gtk.Box CreateRuleWidget(TransparencyRule rule, Action onRemove, Action onChange)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var matchEntry = Gtk.Entry.New();
            var matchBuffer = matchEntry.GetBuffer();
            matchBuffer.SetText(rule.MatchCriteria, -1);
            matchEntry.Hexpand = true;
            matchEntry.OnChanged += (s, e) =>
            {
                rule.MatchCriteria = matchBuffer.GetText();
                onChange();
            };
            row.Append(matchEntry);

            var alphaSlider = Gtk.Scale.NewWithRange(Orientation.Horizontal, 0.1, 1.0, 0.05);
            alphaSlider.DrawValue = true;
            alphaSlider.SetValue(rule.Alpha);
            alphaSlider.SetSizeRequest(100, -1);
            alphaSlider.OnChangeValue += (s, e) =>
            {
                rule.Alpha = e.Value;
                onChange();
                return false;
            };
            row.Append(alphaSlider);

            var removeBtn = Gtk.Button.NewFromIconName("user-trash-symbolic");
            removeBtn.AddCssClass("settings-button");
            removeBtn.OnClicked += (s, e) => onRemove();
            row.Append(removeBtn);

            return row;
        }
    }
}
