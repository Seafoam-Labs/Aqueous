using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Aqueous.Features.SystemTray;
using Aqueous.Features.Bar;

namespace Aqueous.Widgets.SystemTray
{
    public class SystemTrayWidget
    {
        private readonly Gtk.Box _box;
        private readonly SystemTrayService _service;
        private readonly BarWindow? _barWindow;
        private readonly Dictionary<string, Gtk.Button> _buttons = new();
        private int _openPopoverCount;

        public Gtk.Box Box => _box;

        public SystemTrayWidget(SystemTrayService service, BarWindow? barWindow = null)
        {
            _service = service;
            _barWindow = barWindow;

            _box = Gtk.Box.New(Gtk.Orientation.Horizontal, 4);
            _box.AddCssClass("system-tray-box");

            service.ItemsChanged += () =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    Rebuild();
                    return false;
                });
            };

            // Initial rebuild in case items are already present
            Rebuild();
        }

        private void Rebuild()
        {
            // Remove old buttons
            foreach (var btn in _buttons.Values)
                _box.Remove(btn);
            _buttons.Clear();

            foreach (var item in _service.Items)
            {
                if (item.Status == "Passive")
                    continue;

                // Skip items with no icon — they have no meaningful tray presence
                if (string.IsNullOrEmpty(item.IconName) && item.IconPixmap is not { Length: > 0 })
                    continue;

                var button = Gtk.Button.New();
                button.AddCssClass("system-tray-button");

                var icon = IconResolver.Resolve(item);
                if (icon != null)
                {
                    icon.SetPixelSize(22);
                    button.SetChild(icon);
                }
                else
                {
                    var fallback = Gtk.Image.NewFromIconName("application-x-executable");
                    fallback.SetPixelSize(22);
                    button.SetChild(fallback);
                }

                if (!string.IsNullOrEmpty(item.ToolTipTitle))
                    button.SetTooltipText(item.ToolTipTitle);
                else if (!string.IsNullOrEmpty(item.Title))
                    button.SetTooltipText(item.Title);

                // Left click — activate
                var capturedItem = item;
                button.OnClicked += (_, _) =>
                {
                    Task.Run(async () =>
                    {
                        if (_service.Host != null)
                            await _service.Host.ActivateItemAsync(capturedItem);
                    });
                };

                // Right click — context menu via GestureClick
                var rightClick = Gtk.GestureClick.New();
                rightClick.SetButton(3); // right mouse button
                rightClick.OnReleased += (gesture, args) =>
                {
                    if (!string.IsNullOrEmpty(capturedItem.MenuPath) && _service.Host != null)
                    {
                        Task.Run(async () =>
                        {
                            var parts = capturedItem.ServiceName.Split('/', 2);
                            var busName = parts[0];
                            var menuItems = await _service.Host.MenuProxy.GetMenuItemsAsync(busName, capturedItem.MenuPath);
                            GLib.Functions.IdleAdd(0, () =>
                            {
                                ShowContextMenu(button, menuItems, busName, capturedItem.MenuPath);
                                return false;
                            });
                        });
                    }
                };
                button.AddController(rightClick);

                _buttons[item.ServiceName] = button;
                _box.Append(button);
            }
        }

        private void ShowContextMenu(Gtk.Button anchor, List<MenuItem> menuItems, string busName, string menuPath)
        {
            var popover = Gtk.Popover.New();
            popover.SetParent(anchor);

            var vbox = Gtk.Box.New(Gtk.Orientation.Vertical, 2);
            vbox.AddCssClass("system-tray-menu");

            foreach (var mi in menuItems)
            {
                if (!mi.Visible) continue;

                if (mi.IsSeparator)
                {
                    var sep = Gtk.Separator.New(Gtk.Orientation.Horizontal);
                    vbox.Append(sep);
                    continue;
                }

                var label = mi.Label.Replace("_", "");
                var menuButton = Gtk.Button.NewWithLabel(label);
                menuButton.AddCssClass("system-tray-menu-item");
                menuButton.SetSensitive(mi.Enabled);

                var capturedId = mi.Id;
                menuButton.OnClicked += (_, _) =>
                {
                    popover.Popdown();
                    if (_service.Host != null)
                    {
                        Task.Run(async () =>
                        {
                            await _service.Host.MenuProxy.ActivateMenuItemAsync(busName, menuPath, capturedId);
                        });
                    }
                };

                vbox.Append(menuButton);
            }

            popover.SetChild(vbox);

            // Prevent bar auto-hide while popover is open
            _openPopoverCount++;
            _barWindow?.ShowBar();

            popover.OnClosed += (_, _) =>
            {
                _openPopoverCount--;
                popover.Unparent();
            };

            popover.Popup();
        }
    }
}
