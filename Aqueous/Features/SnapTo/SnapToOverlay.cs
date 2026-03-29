using System;
using System.Collections.Generic;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Gtk;

namespace Aqueous.Features.SnapTo
{
    public class SnapToOverlay
    {
        private readonly List<ZoneLayout> _layouts;
        private int _currentLayoutIndex;
        private AstalWindow? _window;
        private AstalApplication _app;
        private int _screenW = 1920;
        private int _screenH = 1080;
        public bool IsVisible { get; private set; }

        public SnapToOverlay(AstalApplication app, List<ZoneLayout> layouts)
        {
            _app = app;
            _layouts = layouts;
        }

        public async void Show()
        {
            if (IsVisible) return;

            var layout = _layouts[_currentLayoutIndex];

            // Get screen dimensions from wf-msg
            try
            {
                var outputs = await WayfireIpc.ListOutputs();
                if (outputs.Length > 0)
                {
                    if (outputs[0].TryGetProperty("width", out var w))
                        _screenW = w.GetInt32();
                    if (outputs[0].TryGetProperty("height", out var h))
                        _screenH = h.GetInt32();
                }
            }
            catch
            {
                // Fall back to defaults
            }

            _window = new AstalWindow();
            _app.GtkApplication.AddWindow(_window.GtkWindow);
            _window.Namespace = "snapto-overlay";
            _window.Layer = AstalLayer.ASTAL_LAYER_OVERLAY;
            _window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_IGNORE;
            _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                           | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_BOTTOM
                           | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT
                           | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;
            _window.Keymode = AstalKeymode.ASTAL_KEYMODE_EXCLUSIVE;

            // Use a Fixed container for absolute positioning of zones
            var overlay = Gtk.Fixed.New();
            overlay.SetSizeRequest(_screenW, _screenH);
            overlay.AddCssClass("snapto-overlay");

            foreach (var zone in layout.Zones)
            {
                var x = (int)(zone.X * _screenW);
                var y = (int)(zone.Y * _screenH);
                var w = (int)(zone.Width * _screenW);
                var h = (int)(zone.Height * _screenH);

                var zoneButton = Gtk.Button.New();
                zoneButton.SetSizeRequest(w, h);
                zoneButton.AddCssClass("zone");

                var label = Gtk.Label.New(zone.Name);
                label.AddCssClass("zone-label");
                zoneButton.SetChild(label);

                var capturedZone = zone;
                zoneButton.OnClicked += (sender, args) =>
                {
                    SnapToZone(capturedZone);
                };

                overlay.Put(zoneButton, x, y);
            }

            // Handle Escape key to hide
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

            _window.GtkWindow.SetChild(overlay);
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

        public void CycleLayout()
        {
            _currentLayoutIndex = (_currentLayoutIndex + 1) % _layouts.Count;
            if (IsVisible)
            {
                Hide();
                Show();
            }
        }

        private async void SnapToZone(Zone zone)
        {
            Hide();

            try
            {
                var focused = await WayfireIpc.GetFocusedView();
                if (focused == null) return;

                var viewId = focused.Value.GetProperty("id").GetInt32();

                var x = (int)(zone.X * _screenW);
                var y = (int)(zone.Y * _screenH);
                var w = (int)(zone.Width * _screenW);
                var h = (int)(zone.Height * _screenH);

                await WayfireIpc.SetViewGeometry(viewId, x, y, w, h);
            }
            catch
            {
                // Silently fail if wf-msg is unavailable
            }
        }
    }
}
