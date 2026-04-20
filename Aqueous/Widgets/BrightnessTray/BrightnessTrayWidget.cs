using Aqueous.Features.Bar;
using Aqueous.Features.Brightness;
using Gtk;

namespace Aqueous.Widgets.BrightnessTray
{
    public class BrightnessTrayWidget
    {
        private readonly Gtk.Button _button;
        private readonly BarWindow? _barWindow;
        public Gtk.Button Button => _button;

        public BrightnessTrayWidget(BrightnessService service, BarWindow? barWindow = null)
        {
            _barWindow = barWindow;
            _button = Gtk.Button.New();
            _button.AddCssClass("brightness-tray-button");

            var label = Gtk.Label.New("󰃟");
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
                service.Toggle(_button);
            };

            // Scroll: adjust brightness up/down by 5%
            var scroll = Gtk.EventControllerScroll.New(Gtk.EventControllerScrollFlags.Vertical);
            scroll.OnScroll += (sender, args) =>
            {
                if (args.Dy < 0)
                    BrightnessBackend.SetBrightnessAsync("+5%").ContinueWith(_ => { });
                else
                    BrightnessBackend.SetBrightnessAsync("5%-").ContinueWith(_ => { });
                return true;
            };
            _button.AddController(scroll);

            service.BrightnessChanged += () =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    // Icon stays as generic brightness icon
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
    }
}
