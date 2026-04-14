using System;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Gtk;

namespace Aqueous.Features.Brightness
{
    public class BrightnessPopup
    {
        private readonly AstalApplication _app;
        private AstalWindow? _window;
        private CancellationTokenSource? _debounceCts;
        public bool IsVisible { get; private set; }

        public BrightnessPopup(AstalApplication app)
        {
            _app = app;
        }

        public async void Show()
        {
            if (IsVisible) return;

            var percent = await BrightnessBackend.GetBrightnessPercentAsync();

            _window = new AstalWindow();
            _app.GtkApplication.AddWindow(_window.GtkWindow);
            _window.Namespace = "brightness-popup";
            _window.Layer = AstalLayer.ASTAL_LAYER_OVERLAY;
            _window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_IGNORE;
            _window.Keymode = AstalKeymode.ASTAL_KEYMODE_EXCLUSIVE;
            _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                           | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;

            var container = Gtk.Box.New(Orientation.Vertical, 8);
            container.AddCssClass("brightness-popup");

            // Header
            var header = Gtk.Label.New("Brightness");
            header.AddCssClass("brightness-header");
            header.SetHalign(Align.Start);
            container.Append(header);

            // Slider row
            var sliderRow = Gtk.Box.New(Orientation.Horizontal, 8);
            sliderRow.AddCssClass("brightness-slider-row");

            var icon = Gtk.Label.New(GetIcon(percent));
            icon.AddCssClass("brightness-icon");
            sliderRow.Append(icon);

            var slider = Gtk.Scale.NewWithRange(Orientation.Horizontal, 0, 100, 1);
            slider.SetValue(percent);
            slider.Hexpand = true;
            slider.AddCssClass("brightness-slider");
            sliderRow.Append(slider);

            var percentLabel = Gtk.Label.New($"{percent}%");
            percentLabel.AddCssClass("brightness-label");
            sliderRow.Append(percentLabel);

            container.Append(sliderRow);

            slider.OnChangeValue += (scale, args) =>
            {
                var value = (int)args.Value;
                percentLabel.SetText($"{value}%");
                icon.SetText(GetIcon(value));
                DebounceSetBrightness(value);
                return false;
            };

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

            _window.GtkWindow.SetChild(container);
            _window.GtkWindow.Present();
            IsVisible = true;
        }

        public void Hide()
        {
            if (!IsVisible || _window == null) return;
            _window.GtkWindow.Close();
            _window = null;
            IsVisible = false;
        }

        private async void DebounceSetBrightness(int percent)
        {
            _debounceCts?.Cancel();
            _debounceCts = new CancellationTokenSource();
            var token = _debounceCts.Token;

            try
            {
                await Task.Delay(80, token);
                if (token.IsCancellationRequested) return;
                await BrightnessBackend.SetBrightnessAsync(percent);
            }
            catch (OperationCanceledException)
            {
                // Debounce cancelled, ignore
            }
        }

        private static string GetIcon(int percent)
        {
            return percent switch
            {
                <= 0 => "󰃞",
                <= 33 => "󰃞",
                <= 66 => "󰃟",
                _ => "󰃠"
            };
        }
    }
}
