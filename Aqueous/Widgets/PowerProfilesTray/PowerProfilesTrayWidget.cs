using Aqueous.Features.Bar;
using Aqueous.Features.PowerProfiles;
using Gtk;
namespace Aqueous.Widgets.PowerProfilesTray
{
    public class PowerProfilesTrayWidget
    {
        private readonly Gtk.Button _button;
        private readonly BarWindow? _barWindow;
        public Gtk.Button Button => _button;
        public PowerProfilesTrayWidget(PowerProfilesService service, BarWindow? barWindow = null)
        {
            _barWindow = barWindow;
            _button = Gtk.Button.New();
            _button.AddCssClass("power-profiles-tray-button");
            var label = Gtk.Label.New(GetIcon(service.ActiveProfile));
            _button.SetChild(label);
            // Left-click: toggle popup
            _button.OnClicked += (_, _) =>
            {
                if (!service.IsPopupVisible)
                {
                    _barWindow?.PreventHide();
                }
                else
                {
                    _barWindow?.AllowHide();
                }
                service.Toggle();
            };
            // Right-click: cycle profile
            var rightClick = Gtk.GestureClick.New();
            rightClick.SetButton(3);
            rightClick.OnReleased += (_, _) =>
            {
                service.CycleProfile();
            };
            _button.AddController(rightClick);
            // Scroll: cycle profile
            var scroll = Gtk.EventControllerScroll.New(Gtk.EventControllerScrollFlags.Vertical);
            scroll.OnScroll += (_, args) =>
            {
                service.CycleProfile();
                return true;
            };
            _button.AddController(scroll);
            service.ProfileChanged += () =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    label.SetText(GetIcon(service.ActiveProfile));
                    return false;
                });
            };
            // Allow hide when popup is closed externally
            service.PopupClosed += () =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    _barWindow?.AllowHide();
                    return false;
                });
            };
        }
        private static string GetIcon(string? profile)
        {
            return profile switch
            {
                "performance" => "󰓅",
                "power-saver" => "󰾆",
                _ => "󰾅" // balanced or unknown
            };
        }
    }
}
