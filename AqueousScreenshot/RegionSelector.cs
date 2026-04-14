using System;
using System.Threading.Tasks;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;

namespace AqueousScreenshot
{
    public class RegionSelector
    {
        private readonly AstalApplication _app;
        private AstalWindow? _overlay;
        private Gtk.DrawingArea? _drawingArea;
        private Gtk.Label? _dimensionLabel;

        private bool _dragging;
        private double _startX, _startY;
        private double _currentX, _currentY;

        private TaskCompletionSource<(int X, int Y, int W, int H)?> _tcs = new();

        public RegionSelector(AstalApplication app)
        {
            _app = app;
        }

        public Task<(int X, int Y, int W, int H)?> SelectRegionAsync()
        {
            _tcs = new TaskCompletionSource<(int X, int Y, int W, int H)?>();
            ShowOverlay();
            return _tcs.Task;
        }

        private void ShowOverlay()
        {
            _overlay = new AstalWindow();
            _overlay.Namespace = "screenshot-region-selector";
            _overlay.Layer = AstalLayer.ASTAL_LAYER_OVERLAY;
            _overlay.Keymode = AstalKeymode.ASTAL_KEYMODE_EXCLUSIVE;
            _overlay.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                            | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_BOTTOM
                            | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT
                            | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;

            _overlay.GtkWindow.AddCssClass("region-selector-window");

            var overlayWidget = Gtk.Overlay.New();

            _drawingArea = Gtk.DrawingArea.New();
            _drawingArea.SetHexpand(true);
            _drawingArea.SetVexpand(true);
            _drawingArea.SetDrawFunc(DrawSelection);
            overlayWidget.SetChild(_drawingArea);

            _dimensionLabel = Gtk.Label.New("");
            _dimensionLabel.AddCssClass("region-dimension-label");
            _dimensionLabel.SetHalign(Gtk.Align.Center);
            _dimensionLabel.SetValign(Gtk.Align.Center);
            _dimensionLabel.SetVisible(false);
            overlayWidget.AddOverlay(_dimensionLabel);

            _overlay.GtkWindow.SetChild(overlayWidget);

            // Mouse click/drag
            var clickGesture = Gtk.GestureDrag.New();
            clickGesture.OnDragBegin += OnDragBegin;
            clickGesture.OnDragUpdate += OnDragUpdate;
            clickGesture.OnDragEnd += OnDragEnd;
            _overlay.GtkWindow.AddController(clickGesture);

            // Escape to cancel
            var keyController = Gtk.EventControllerKey.New();
            keyController.OnKeyPressed += OnKeyPressed;
            _overlay.GtkWindow.AddController(keyController);

            _overlay.GtkWindow.Present();
        }

        private void OnDragBegin(Gtk.GestureDrag sender, Gtk.GestureDrag.DragBeginSignalArgs args)
        {
            _dragging = true;
            _startX = args.StartX;
            _startY = args.StartY;
            _currentX = args.StartX;
            _currentY = args.StartY;
            _dimensionLabel?.SetVisible(true);
            _drawingArea?.QueueDraw();
        }

        private void OnDragUpdate(Gtk.GestureDrag sender, Gtk.GestureDrag.DragUpdateSignalArgs args)
        {
            _currentX = _startX + args.OffsetX;
            _currentY = _startY + args.OffsetY;

            var w = (int)Math.Abs(args.OffsetX);
            var h = (int)Math.Abs(args.OffsetY);
            _dimensionLabel?.SetLabel($"{w} × {h}");

            _drawingArea?.QueueDraw();
        }

        private void OnDragEnd(Gtk.GestureDrag sender, Gtk.GestureDrag.DragEndSignalArgs args)
        {
            _dragging = false;

            var endX = _startX + args.OffsetX;
            var endY = _startY + args.OffsetY;

            var x = (int)Math.Min(_startX, endX);
            var y = (int)Math.Min(_startY, endY);
            var w = (int)Math.Abs(args.OffsetX);
            var h = (int)Math.Abs(args.OffsetY);

            CloseOverlay();

            if (w > 5 && h > 5)
                _tcs.TrySetResult((x, y, w, h));
            else
                _tcs.TrySetResult(null);
        }

        private bool OnKeyPressed(Gtk.EventControllerKey sender, Gtk.EventControllerKey.KeyPressedSignalArgs args)
        {
            if (args.Keyval == 0xff1b) // GDK_KEY_Escape
            {
                CloseOverlay();
                _tcs.TrySetResult(null);
                return true;
            }
            return false;
        }

        private void DrawSelection(Gtk.DrawingArea area, Cairo.Context cr, int width, int height)
        {
            // Semi-transparent dark overlay
            cr.SetSourceRgba(0.0, 0.0, 0.0, 0.3);
            cr.Rectangle(0, 0, width, height);
            cr.Fill();

            if (!_dragging) return;

            var x = Math.Min(_startX, _currentX);
            var y = Math.Min(_startY, _currentY);
            var w = Math.Abs(_currentX - _startX);
            var h = Math.Abs(_currentY - _startY);

            // Clear the selected region (punch through the overlay)
            cr.Operator = Cairo.Operator.Clear;
            cr.Rectangle(x, y, w, h);
            cr.Fill();

            // Draw selection border
            cr.Operator = Cairo.Operator.Over;
            cr.SetSourceRgba(0.537, 0.706, 0.98, 1.0); // #89b4fa
            cr.LineWidth = 2.0;
            cr.Rectangle(x, y, w, h);
            cr.Stroke();
        }

        private void CloseOverlay()
        {
            if (_overlay != null)
            {
                _overlay.GtkWindow.Close();
                _overlay = null;
                _drawingArea = null;
                _dimensionLabel = null;
            }
        }
    }
}
