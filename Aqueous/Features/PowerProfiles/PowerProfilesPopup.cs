using System;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Aqueous.Helpers;
using Gtk;
namespace Aqueous.Features.PowerProfiles
{
    public class PowerProfilesPopup
    {
        private readonly AstalApplication _app;
        private readonly PowerProfilesBackend _backend;
        private AstalWindow? _window;
        private AstalWindow? _backdrop;
        public bool IsVisible { get; private set; }
        public PowerProfilesPopup(AstalApplication app, PowerProfilesBackend backend)
        {
            _app = app;
            _backend = backend;
        }
        public void Show(Gtk.Button? anchorButton = null)
        {
            if (IsVisible) return;
            IsVisible = true;
            BuildWindow(anchorButton);
        }
        public void Hide()
        {
            if (!IsVisible) return;
            IsVisible = false;
            BackdropHelper.DestroyBackdrop(ref _backdrop);
            BackdropHelper.DestroyWindow(ref _window);
        }
        private void BuildWindow(Gtk.Button? anchorButton)
        {
            _window = new AstalWindow();
            _app.GtkApplication.AddWindow(_window.GtkWindow);
            _window.Namespace = "power-profiles-popup";
            _window.Layer = AstalLayer.ASTAL_LAYER_OVERLAY;
            _window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_IGNORE;
            // Pointer-only popup (radio list). NONE prevents compositor swallowing the first click.
            _window.Keymode = AstalKeymode.ASTAL_KEYMODE_NONE;

            var mainBox = Gtk.Box.New(Orientation.Vertical, 8);
            mainBox.AddCssClass("power-profiles-popup");
            // Header
            var header = Gtk.Label.New("Power Profile");
            header.AddCssClass("power-profiles-header");
            header.SetHalign(Align.Start);
            mainBox.Append(header);
            // Profile rows
            var activeProfile = _backend.ActiveProfile ?? "balanced";
            AddProfileRow(mainBox, "performance", "󰓅", "Performance", activeProfile);
            AddProfileRow(mainBox, "balanced", "󰾅", "Balanced", activeProfile);
            AddProfileRow(mainBox, "power-saver", "󰾆", "Power Saver", activeProfile);
            // Performance degraded warning
            var degraded = _backend.PerformanceDegraded;
            if (!string.IsNullOrEmpty(degraded))
            {
                var warning = Gtk.Label.New($"⚠ Performance degraded: {degraded}");
                warning.AddCssClass("degraded-warning");
                warning.SetHalign(Align.Start);
                mainBox.Append(warning);
            }
            // Active holds
            var holds = _backend.ActiveHolds;
            if (holds != null && holds.Length > 0)
            {
                var holdsLabel = Gtk.Label.New("Active Holds:");
                holdsLabel.AddCssClass("power-profiles-holds-header");
                holdsLabel.SetHalign(Align.Start);
                mainBox.Append(holdsLabel);
                foreach (var hold in holds)
                {
                    var holdRow = Gtk.Label.New($"  {hold.ApplicationId ?? "Unknown"}: {hold.Reason ?? ""}");
                    holdRow.AddCssClass("power-profiles-hold-row");
                    holdRow.SetHalign(Align.Start);
                    mainBox.Append(holdRow);
                }
            }

            if (anchorButton != null)
            {
                var (x, y) = WidgetGeometryHelper.GetWidgetGlobalPos(anchorButton);
                var (screenWidth, screenHeight) = WidgetGeometryHelper.GetScreenSize();

                mainBox.Measure(Orientation.Horizontal, -1, out _, out var natWidth, out _, out _);
                mainBox.Measure(Orientation.Vertical, -1, out _, out var natHeight, out _, out _);

                int popupWidth = Math.Max(250, natWidth);
                int popupHeight = Math.Max(200, natHeight);

                _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT;

                int targetX = x + (anchorButton.GetAllocatedWidth() / 2) - (popupWidth / 2);
                int targetY = y + anchorButton.GetAllocatedHeight() + 4; // Tiny gap

                // Keep it on screen
                if (targetX + popupWidth > screenWidth - 10) targetX = screenWidth - popupWidth - 10;
                if (targetX < 10) targetX = 10;

                if (targetY + popupHeight > screenHeight - 10)
                {
                    targetY = Math.Max(10, y - popupHeight - 4);
                }

                _window.MarginLeft = targetX;
                _window.MarginTop = targetY;
            }
            else
            {
                _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                               | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;
            }
            // Escape key to dismiss
            var keyController = Gtk.EventControllerKey.New();
            keyController.OnKeyPressed += (controller, args) =>
            {
                if (args.Keyval == 0xff1b) // GDK_KEY_Escape
                {
                    Hide();
                    return true;
                }
                return false;
            };
            _window.GtkWindow.AddController(keyController);

            _backdrop = BackdropHelper.CreateBackdrop(_app, "power-profiles-backdrop", AstalLayer.ASTAL_LAYER_OVERLAY, Hide);

            _window.GtkWindow.SetChild(mainBox);
            _window.GtkWindow.Present();
        }
        private void AddProfileRow(Gtk.Box container, string profileId, string icon, string label, string activeProfile)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("power-profile-row");
            if (profileId == activeProfile)
                row.AddCssClass("active");
            var iconLabel = Gtk.Label.New(icon);
            iconLabel.AddCssClass("power-profile-icon");
            row.Append(iconLabel);
            var nameLabel = Gtk.Label.New(label);
            nameLabel.SetHexpand(true);
            nameLabel.SetHalign(Align.Start);
            row.Append(nameLabel);
            if (profileId == activeProfile)
            {
                var check = Gtk.Label.New("✓");
                check.AddCssClass("power-profile-check");
                row.Append(check);
            }
            var click = Gtk.GestureClick.New();
            click.OnReleased += (_, _) =>
            {
                _backend.ActiveProfile = profileId;
                Hide();
                Show();
            };
            row.AddController(click);
            container.Append(row);
        }
    }
}
