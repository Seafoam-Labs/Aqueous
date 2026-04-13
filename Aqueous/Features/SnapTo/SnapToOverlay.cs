using System;
using System.Collections.Generic;
using System.Threading.Tasks;
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

        public async void Show(bool isDragMode = false)
        {
            if (IsVisible) return;

            var layout = _layouts[_currentLayoutIndex];

            // Get screen dimensions from Wayfire IPC
            try
            {
                var outputs = await WayfireIpc.ListOutputs();
                Console.WriteLine("[SnapTo] ListOutputs returned " + outputs.Length + " output(s)");
                if (outputs.Length > 0)
                {
                    Console.WriteLine("[SnapTo] Output[0]: " + outputs[0].ToString());

                    if (outputs[0].TryGetProperty("geometry", out var geo))
                    {
                        if (geo.TryGetProperty("width", out var w))
                            _screenW = w.GetInt32();
                        if (geo.TryGetProperty("height", out var h))
                            _screenH = h.GetInt32();
                    }
                }
                Console.WriteLine($"[SnapTo] Screen resolution: {_screenW}x{_screenH}");
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[SnapTo] Failed to get screen resolution via Wayfire IPC: {ex.Message}");
            }

            _window = new AstalWindow();
            _app.GtkApplication.AddWindow(_window.GtkWindow);
            _window.Namespace = "snapto-overlay";
            _window.Layer = isDragMode
                ? AstalLayer.ASTAL_LAYER_BOTTOM
                : AstalLayer.ASTAL_LAYER_OVERLAY;
            _window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_IGNORE;
            _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                           | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_BOTTOM
                           | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT
                           | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;
            _window.Keymode = isDragMode
                ? AstalKeymode.ASTAL_KEYMODE_NONE
                : AstalKeymode.ASTAL_KEYMODE_EXCLUSIVE;

            // Use a Fixed container for absolute positioning of zones
            var overlay = Gtk.Fixed.New();
            overlay.SetSizeRequest(_screenW, _screenH);
            overlay.AddCssClass("snapto-overlay");

            foreach (var zone in layout.Zones)
            {
                var zoneX = (int)(zone.X * _screenW);
                var zoneY = (int)(zone.Y * _screenH);
                var zoneW = (int)(zone.Width * _screenW);
                var zoneH = (int)(zone.Height * _screenH);

                var capturedZone = zone;

                // Centered visible indicator
                const int indicatorW = 150;
                const int indicatorH = 80;
                var centerX = zoneX + (zoneW - indicatorW) / 2;
                var centerY = zoneY + (zoneH - indicatorH) / 2;

                var zoneButton = Gtk.Button.New();
                zoneButton.SetSizeRequest(indicatorW, indicatorH);
                zoneButton.AddCssClass("flat");
                zoneButton.AddCssClass("zone");

                var label = Gtk.Label.New(zone.Name);
                label.AddCssClass("zone-label");
                zoneButton.SetChild(label);

                zoneButton.OnClicked += (sender, args) => { SnapToZone(capturedZone); };

                // Option C: Right-click opens zone editor with this zone pre-selected
                var rightClick = Gtk.GestureClick.New();
                rightClick.SetButton(3);
                var capturedZoneForEdit = zone;
                rightClick.OnReleased += (gesture, args) =>
                {
                    Hide();
                    var editor = new SnapToEditorPopup(_app, SnapToConfig.Load());
                    editor.Show(preSelectedZone: capturedZoneForEdit.Name);
                };
                zoneButton.AddController(rightClick);

                // Option C: Long-press for touchscreen
                var longPress = Gtk.GestureLongPress.New();
                longPress.OnPressed += (gesture, args) =>
                {
                    Hide();
                    var editor = new SnapToEditorPopup(_app, SnapToConfig.Load());
                    editor.Show(preSelectedZone: capturedZoneForEdit.Name);
                };
                zoneButton.AddController(longPress);

                overlay.Put(zoneButton, centerX, centerY);
            }

            if (!isDragMode)
            {
                // Handle Escape key to hide (only in non-drag mode)
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
            }

            _window.GtkWindow.AddCssClass("snapto-overlay");
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

        public async Task SnapToZoneAtCursor()
        {
            var layout = _layouts[_currentLayoutIndex];

            try
            {
                var cursorPos = await WayfireIpc.GetCursorPosition();
                if (cursorPos == null) return;

                var (cursorX, cursorY) = cursorPos.Value;

                const int indicatorW = 150;
                const int indicatorH = 80;

                foreach (var zone in layout.Zones)
                {
                    var zx = (int)(zone.X * _screenW);
                    var zy = (int)(zone.Y * _screenH);
                    var zw = (int)(zone.Width * _screenW);
                    var zh = (int)(zone.Height * _screenH);

                    // Hit-test against the centered indicator bounds, not the full zone
                    var centerX = zx + (zw - indicatorW) / 2;
                    var centerY = zy + (zh - indicatorH) / 2;

                    if (cursorX >= centerX && cursorX < centerX + indicatorW &&
                        cursorY >= centerY && cursorY < centerY + indicatorH)
                    {
                        var focused = await WayfireIpc.GetFocusedView();
                        if (focused == null) return;

                        var viewId = focused.Value.GetProperty("id").GetInt32();
                        await WayfireIpc.SetViewGeometry(viewId, zx, zy, zw, zh);
                        return;
                    }
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[SnapTo] SnapToZoneAtCursor error: {ex.Message}");
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
