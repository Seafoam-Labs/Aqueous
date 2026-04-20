using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Aqueous.Features.Settings;
using Gtk;

namespace Aqueous.Features.MediaPlayer
{
    public class MediaPlayerWindow
    {
        private const int PanelWidth = 350;
        private const int PanelHeight = 120;
        private const int HitboxHeight = 2;
        private const int CavaBars = 20;
        private const int CavaMaxHeight = 30;

        private readonly AstalApplication _app;
        private AstalWindow? _panel;
        private bool _visible;
        private bool _locked;
        private uint _hideTimeout;

        // UI elements
        private Gtk.Box? _mainBox;
        private Gtk.Label? _titleLabel;
        private Gtk.Label? _artistLabel;
        private Gtk.Button? _playPauseButton;
        private Gtk.Button? _lockButton;
        private Gtk.DrawingArea? _cavaDrawingArea;
        private float[] _cavaValues = new float[CavaBars];

        public event Action? OnPrevious;
        public event Action? OnPlayPause;
        public event Action? OnNext;

        public MediaPlayerWindow(AstalApplication app)
        {
            _app = app;
        }

        public void Show()
        {
            CreatePanel();
            _panel?.GtkWindow.Present();
            _visible = false;
            ShowPanel();
            ScheduleHide();
        }

        public void Hide()
        {
            DestroyPanel();
        }

        public void SetLocked(bool locked)
        {
            _locked = locked;
            if (_lockButton != null)
            {
                if (_locked)
                {
                    _lockButton.AddCssClass("media-player-lock-active");
                    _lockButton.SetLabel("🔒");
                }
                else
                {
                    _lockButton.RemoveCssClass("media-player-lock-active");
                    _lockButton.SetLabel("🔓");
                }
            }
            if (!_locked)
                ScheduleHide();
            else
            {
                CancelHideTimeout();
                ShowPanel();
            }
        }

        public void UpdateTrackInfo(string? title, string? artist)
        {
            if (_titleLabel != null)
                _titleLabel.SetLabel(title ?? "No Track");
            if (_artistLabel != null)
                _artistLabel.SetLabel(artist ?? "Unknown Artist");
        }

        public void UpdatePlaybackStatus(bool playing)
        {
            if (_playPauseButton != null)
                _playPauseButton.SetLabel(playing ? "⏸" : "▶");
        }

        public void UpdateCavaValues(float[] values)
        {
            _cavaValues = values;
            _cavaDrawingArea?.QueueDraw();
        }

        private void CreatePanel()
        {
            _panel = new AstalWindow();
            _app.GtkApplication.AddWindow(_panel.GtkWindow);
            _panel.Namespace = "media-player-panel";
            _panel.Layer = AstalLayer.ASTAL_LAYER_TOP;
            _panel.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_NORMAL;
            _panel.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_BOTTOM
                          | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;

            _panel.GtkWindow.SetDecorated(false);
            _panel.GtkWindow.AddCssClass("media-player-panel");
            _panel.GtkWindow.SetDefaultSize(PanelWidth, HitboxHeight);
            _panel.MarginBottom = 10;
            _panel.MarginRight = 10;

            _mainBox = Gtk.Box.New(Gtk.Orientation.Vertical, 4);
            _mainBox.AddCssClass("media-player-container");

            // Lock button row
            var topRow = Gtk.Box.New(Gtk.Orientation.Horizontal, 0);
            topRow.SetHalign(Gtk.Align.End);
            _lockButton = Gtk.Button.New();
            _lockButton.SetLabel("🔓");
            _lockButton.AddCssClass("media-player-lock-button");
            _lockButton.OnClicked += (_, _) => SetLocked(!_locked);
            topRow.Append(_lockButton);
            _mainBox.Append(topRow);

            // Cava visualizer
            _cavaDrawingArea = Gtk.DrawingArea.New();
            _cavaDrawingArea.SetContentWidth(PanelWidth - 24);
            _cavaDrawingArea.SetContentHeight(CavaMaxHeight);
            _cavaDrawingArea.AddCssClass("media-player-cava-container");
            _cavaDrawingArea.SetDrawFunc(DrawCava);
            _mainBox.Append(_cavaDrawingArea);

            // Track info
            _titleLabel = Gtk.Label.New("No Track");
            _titleLabel.AddCssClass("media-player-track-title");
            _titleLabel.SetHalign(Gtk.Align.Center);
            _titleLabel.SetEllipsize(Pango.EllipsizeMode.End);
            _titleLabel.SetMaxWidthChars(30);
            _mainBox.Append(_titleLabel);

            _artistLabel = Gtk.Label.New("Unknown Artist");
            _artistLabel.AddCssClass("media-player-track-artist");
            _artistLabel.SetHalign(Gtk.Align.Center);
            _artistLabel.SetEllipsize(Pango.EllipsizeMode.End);
            _artistLabel.SetMaxWidthChars(30);
            _mainBox.Append(_artistLabel);

            // Media controls
            var controlsBox = Gtk.Box.New(Gtk.Orientation.Horizontal, 4);
            controlsBox.AddCssClass("media-player-controls");
            controlsBox.SetHalign(Gtk.Align.Center);

            var prevButton = Gtk.Button.New();
            prevButton.SetLabel("⏮");
            prevButton.OnClicked += (_, _) => OnPrevious?.Invoke();
            controlsBox.Append(prevButton);

            _playPauseButton = Gtk.Button.New();
            _playPauseButton.SetLabel("▶");
            _playPauseButton.OnClicked += (_, _) => OnPlayPause?.Invoke();
            controlsBox.Append(_playPauseButton);

            var nextButton = Gtk.Button.New();
            nextButton.SetLabel("⏭");
            nextButton.OnClicked += (_, _) => OnNext?.Invoke();
            controlsBox.Append(nextButton);

            _mainBox.Append(controlsBox);

            _panel.GtkWindow.SetChild(_mainBox);

            // Mouse enter/leave for auto-hide
            var motionController = Gtk.EventControllerMotion.New();
            motionController.OnEnter += (_, _) => ShowPanel();
            motionController.OnLeave += (_, _) => ScheduleHide();
            _panel.GtkWindow.AddController(motionController);
        }

        private void DrawCava(Gtk.DrawingArea area, Cairo.Context cr, int width, int height)
        {
            var barCount = _cavaValues.Length;
            if (barCount == 0) return;

            var barWidth = (double)width / barCount;
            var gap = 2.0;

            for (int i = 0; i < barCount; i++)
            {
                var value = Math.Clamp(_cavaValues[i], 0f, 1f);
                var barHeight = value * height;
                if (barHeight < 1) barHeight = 1;

                var x = i * barWidth + gap / 2;
                var w = barWidth - gap;
                var y = height - barHeight;

                // Gradient from #89b4fa to #cba6f7
                var t = (double)i / Math.Max(barCount - 1, 1);
                var r = (0x89 + t * (0xcb - 0x89)) / 255.0;
                var g = (0xb4 + t * (0xa6 - 0xb4)) / 255.0;
                var b = (0xfa + t * (0xf7 - 0xfa)) / 255.0;

                cr.SetSourceRgba(r, g, b, 0.9);

                // Rounded rectangle
                var radius = 2.0;
                cr.NewPath();
                cr.Arc(x + w - radius, y + radius, radius, -Math.PI / 2, 0);
                cr.Arc(x + w - radius, y + barHeight - radius, radius, 0, Math.PI / 2);
                cr.Arc(x + radius, y + barHeight - radius, radius, Math.PI / 2, Math.PI);
                cr.Arc(x + radius, y + radius, radius, Math.PI, 3 * Math.PI / 2);
                cr.ClosePath();
                cr.Fill();
            }
        }

        private void ShowPanel()
        {
            CancelHideTimeout();
            if (_panel != null && !_visible)
            {
                _visible = true;
                _panel.GtkWindow.SetDefaultSize(PanelWidth, PanelHeight);
                _panel.GtkWindow.GetChild()?.SetVisible(true);
                _panel.GtkWindow.SetOpacity(SettingsStore.Instance.Data.PanelOpacity);
            }
        }

        private void HidePanel()
        {
            CancelHideTimeout();
            if (_panel != null)
            {
                _panel.GtkWindow.GetChild()?.SetVisible(false);
                _panel.GtkWindow.SetDefaultSize(PanelWidth, HitboxHeight);
                _panel.GtkWindow.SetOpacity(0.01);
            }
            _visible = false;
        }

        private void DestroyPanel()
        {
            CancelHideTimeout();
            if (_panel != null)
            {
                _panel.GtkWindow.Close();
                _panel = null;
                _mainBox = null;
                _titleLabel = null;
                _artistLabel = null;
                _playPauseButton = null;
                _lockButton = null;
                _cavaDrawingArea = null;
            }
            _visible = false;
        }

        private void ScheduleHide()
        {
            if (_locked) return;
            CancelHideTimeout();
            _hideTimeout = GLib.Functions.TimeoutAdd(0, 300, () =>
            {
                HidePanel();
                _hideTimeout = 0;
                return false;
            });
        }

        private void CancelHideTimeout()
        {
            if (_hideTimeout != 0)
            {
                GLib.Functions.SourceRemove(_hideTimeout);
                _hideTimeout = 0;
            }
        }
    }
}
