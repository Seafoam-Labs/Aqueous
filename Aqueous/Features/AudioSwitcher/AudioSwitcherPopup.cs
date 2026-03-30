using System;
using System.Collections.Generic;
using System.Threading;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Gtk;

namespace Aqueous.Features.AudioSwitcher
{
    public class AudioSwitcherPopup
    {
        private readonly AstalApplication _app;
        private AstalWindow? _window;
        private CancellationTokenSource? _debounceCts;
        public bool IsVisible { get; private set; }

        public AudioSwitcherPopup(AstalApplication app)
        {
            _app = app;
        }

        public async void Show()
        {
            if (IsVisible) return;

            var sinks = await AudioBackend.ListSinks();
            var sources = await AudioBackend.ListSources();

            _window = new AstalWindow();
            _app.GtkApplication.AddWindow(_window.GtkWindow);
            _window.Namespace = "audio-switcher";
            _window.Layer = AstalLayer.ASTAL_LAYER_OVERLAY;
            _window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_IGNORE;
            _window.Keymode = AstalKeymode.ASTAL_KEYMODE_EXCLUSIVE;
            _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                           | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;

            var container = Gtk.Box.New(Orientation.Vertical, 4);
            container.AddCssClass("audio-switcher");

            // Speakers section
            if (sinks.Count > 0)
            {
                var sinkHeader = Gtk.Label.New("Speakers");
                sinkHeader.AddCssClass("section-header");
                sinkHeader.Halign = Align.Start;
                container.Append(sinkHeader);

                foreach (var sink in sinks)
                {
                    var row = CreateDeviceRow(sink);
                    container.Append(row);
                }
            }

            // Microphones section
            if (sources.Count > 0)
            {
                var sourceHeader = Gtk.Label.New("Microphones");
                sourceHeader.AddCssClass("section-header");
                sourceHeader.Halign = Align.Start;
                container.Append(sourceHeader);

                foreach (var source in sources)
                {
                    var row = CreateDeviceRow(source);
                    container.Append(row);
                }
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

            var scrolled = Gtk.ScrolledWindow.New();
            scrolled.SetPolicy(PolicyType.Never, PolicyType.Automatic);
            scrolled.SetMaxContentHeight(400);
            scrolled.SetPropagateNaturalHeight(true);
            scrolled.SetChild(container);

            _window.GtkWindow.SetChild(scrolled);
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

        private Gtk.Box CreateDeviceRow(AudioDevice device)
        {
            var row = Gtk.Box.New(Orientation.Vertical, 4);
            row.AddCssClass("audio-device-row");

            // Device select button
            var btn = Gtk.Button.New();
            var label = Gtk.Label.New(device.Description);
            label.Halign = Align.Start;
            btn.SetChild(label);
            btn.AddCssClass("audio-device");

            if (device.IsDefault)
                btn.AddCssClass("active");

            btn.OnClicked += async (sender, args) =>
            {
                if (device.Type == AudioDeviceType.Sink)
                    await AudioBackend.SetDefaultSink(device.Name);
                else
                    await AudioBackend.SetDefaultSource(device.Name);

                // Refresh the popup
                Hide();
                Show();
            };

            // Volume slider
            var slider = Gtk.Scale.NewWithRange(Orientation.Horizontal, 0, 100, 1);
            slider.SetValue(device.Volume);
            slider.Hexpand = true;
            slider.AddCssClass("volume-slider");

            slider.OnChangeValue += (scale, args) =>
            {
                var value = (int)args.Value;
                DebounceSetVolume(device, value);
                return false;
            };

            row.Append(btn);
            row.Append(slider);
            return row;
        }

        private async void DebounceSetVolume(AudioDevice device, int percent)
        {
            _debounceCts?.Cancel();
            _debounceCts = new CancellationTokenSource();
            var token = _debounceCts.Token;

            try
            {
                await System.Threading.Tasks.Task.Delay(80, token);
                if (token.IsCancellationRequested) return;

                if (device.Type == AudioDeviceType.Sink)
                    await AudioBackend.SetSinkVolume(device.Name, percent);
                else
                    await AudioBackend.SetSourceVolume(device.Name, percent);
            }
            catch (OperationCanceledException)
            {
                // Debounce cancelled, ignore
            }
        }
    }
}
