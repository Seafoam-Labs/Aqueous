using System;
using System.Diagnostics;
using Gtk;

namespace Aqueous.Widgets.Dock
{
    public class DockItemWidget
    {
        public Gtk.Button Button { get; }

        public DockItemWidget(string label, string iconName, string execCommand)
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
                try
                {
                    Process.Start(new ProcessStartInfo
                    {
                        FileName = "/bin/sh",
                        Arguments = $"-c \"{execCommand}\"",
                        UseShellExecute = false,
                        CreateNoWindow = true
                    });
                }
                catch
                {
                    // Ignore launch errors
                }
            };
        }
    }
}
