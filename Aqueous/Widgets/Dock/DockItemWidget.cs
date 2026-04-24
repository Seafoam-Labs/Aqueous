using System;
using System.Diagnostics;
using System.Linq;
using Aqueous.Features.SnapTo;
using Aqueous.Features.WindowManager;
using Gtk;

namespace Aqueous.Widgets.Dock
{
    public class DockItemWidget
    {
        public Gtk.Button Button { get; }

        public DockItemWidget(string label, string iconName, string execCommand,
            WindowManagerService? windowManager = null, string? appId = null)
        {
            Button = Gtk.Button.New();
            Button.AddCssClass("dock-item");
            Button.TooltipText = label;

            var icon = Gtk.Image.NewFromIconName(iconName);
            icon.SetPixelSize(32);
            icon.AddCssClass("dock-item-icon");
            Button.SetChild(icon);

            Button.OnClicked += (_, _) =>
            {
                if (windowManager != null && !string.IsNullOrEmpty(appId))
                {
                    var windows = windowManager.Windows
                        .Where(w => w.Role == "toplevel"
                            && !string.IsNullOrEmpty(w.AppId)
                            && w.AppId.Equals(appId, StringComparison.OrdinalIgnoreCase))
                        .ToList();

                    if (windows.Count > 0)
                    {
                        // If the focused window belongs to this app, cycle to the next one
                        var focused = windows.FirstOrDefault(w => w.Focused);
                        TopLevelWindow target;

                        if (focused != null && windows.Count > 1)
                        {
                            var idx = windows.IndexOf(focused);
                            target = windows[(idx + 1) % windows.Count];
                        }
                        else
                        {
                            target = focused ?? windows[0];
                        }

                        if (target.Minimized)
                            _ = Aqueous.Features.Compositor.CompositorBackend.Current.MinimizeView(target.Id, false);

                        _ = Aqueous.Features.Compositor.CompositorBackend.Current.FocusView(target.Id);
                        return;
                    }
                }

                // Shared hardened Wayland spawn so dock-launched apps get
                // WAYLAND_DISPLAY / XDG_RUNTIME_DIR, avoid the silent Xwayland
                // fallback, and receive keyboard/pointer focus on first frame.
                Aqueous.Helpers.WaylandSpawn.Spawn(execCommand);
            };
        }
    }
}
