using System;
using System.IO;
using Aqueous.Bindings.AstalGTK4.Services;

namespace AqueousScreenshot
{
    public class ScreenshotWindow
    {
        private readonly AstalApplication _app;
        private readonly ScreenshotService _service;
        private Gtk.Window _window;
        private Gtk.Picture _preview;
        private Gtk.Label _statusLabel;
        private Gtk.SpinButton _delaySpinner;
        private Gtk.ToggleButton _fullscreenBtn;
        private Gtk.ToggleButton _activeWindowBtn;
        private Gtk.ToggleButton _regionBtn;
        private Gtk.Button _saveAsBtn;
        private Gtk.Button _copyBtn;
        private Gtk.Button _openBtn;
        private Gtk.Button _discardBtn;
        private string? _lastCapturePath;
        private CaptureMode _selectedMode = CaptureMode.Fullscreen;

        public ScreenshotWindow(AstalApplication app, ScreenshotService service)
        {
            _app = app;
            _service = service;

            _window = Gtk.Window.New();
            _window.SetTitle("Aqueous Screenshot");
            _window.SetDefaultSize(600, 500);
            _window.AddCssClass("screenshot-window");

            var mainBox = Gtk.Box.New(Gtk.Orientation.Vertical, 12);
            mainBox.SetMarginTop(12);
            mainBox.SetMarginBottom(12);
            mainBox.SetMarginStart(12);
            mainBox.SetMarginEnd(12);

            // --- Mode selector row ---
            var modeBox = Gtk.Box.New(Gtk.Orientation.Horizontal, 6);
            modeBox.AddCssClass("screenshot-mode-box");
            modeBox.SetHalign(Gtk.Align.Center);

            _fullscreenBtn = Gtk.ToggleButton.New();
            _fullscreenBtn.SetLabel("Fullscreen");
            _fullscreenBtn.AddCssClass("screenshot-mode-btn");
            _fullscreenBtn.SetActive(true);
            _fullscreenBtn.OnToggled += (s, e) => { if (_fullscreenBtn.GetActive()) SelectMode(CaptureMode.Fullscreen); };

            _activeWindowBtn = Gtk.ToggleButton.New();
            _activeWindowBtn.SetLabel("Active Window");
            _activeWindowBtn.AddCssClass("screenshot-mode-btn");
            _activeWindowBtn.SetGroup(_fullscreenBtn);
            _activeWindowBtn.OnToggled += (s, e) => { if (_activeWindowBtn.GetActive()) SelectMode(CaptureMode.ActiveWindow); };

            _regionBtn = Gtk.ToggleButton.New();
            _regionBtn.SetLabel("Region");
            _regionBtn.AddCssClass("screenshot-mode-btn");
            _regionBtn.SetGroup(_fullscreenBtn);
            _regionBtn.OnToggled += (s, e) => { if (_regionBtn.GetActive()) SelectMode(CaptureMode.Region); };

            modeBox.Append(_fullscreenBtn);
            modeBox.Append(_activeWindowBtn);
            modeBox.Append(_regionBtn);

            // --- Delay row ---
            var delayBox = Gtk.Box.New(Gtk.Orientation.Horizontal, 6);
            delayBox.SetHalign(Gtk.Align.Center);
            delayBox.AddCssClass("screenshot-delay-box");

            var delayLabel = Gtk.Label.New("Delay (seconds):");
            _delaySpinner = Gtk.SpinButton.NewWithRange(0, 30, 1);
            _delaySpinner.SetValue(0);

            delayBox.Append(delayLabel);
            delayBox.Append(_delaySpinner);

            // --- Capture button ---
            var captureBtn = Gtk.Button.NewWithLabel("Take Screenshot");
            captureBtn.AddCssClass("screenshot-capture-btn");
            captureBtn.SetHalign(Gtk.Align.Center);
            captureBtn.OnClicked += (s, e) => OnCapture();

            // --- Preview area ---
            _preview = Gtk.Picture.New();
            _preview.SetSizeRequest(400, 300);
            _preview.AddCssClass("screenshot-preview");
            _preview.SetContentFit(Gtk.ContentFit.Contain);

            var previewFrame = Gtk.Frame.New(null);
            previewFrame.AddCssClass("screenshot-preview-frame");
            previewFrame.SetChild(_preview);
            previewFrame.SetVexpand(true);

            // --- Status label ---
            _statusLabel = Gtk.Label.New("");
            _statusLabel.AddCssClass("screenshot-status");

            // --- Action buttons ---
            var actionBox = Gtk.Box.New(Gtk.Orientation.Horizontal, 6);
            actionBox.SetHalign(Gtk.Align.Center);
            actionBox.AddCssClass("screenshot-action-box");

            _saveAsBtn = Gtk.Button.NewWithLabel("Save As...");
            _saveAsBtn.AddCssClass("screenshot-action-btn");
            _saveAsBtn.SetSensitive(false);
            _saveAsBtn.OnClicked += (s, e) => OnSaveAs();

            _copyBtn = Gtk.Button.NewWithLabel("Copy to Clipboard");
            _copyBtn.AddCssClass("screenshot-action-btn");
            _copyBtn.SetSensitive(false);
            _copyBtn.OnClicked += (s, e) => OnCopyToClipboard();

            _openBtn = Gtk.Button.NewWithLabel("Open");
            _openBtn.AddCssClass("screenshot-action-btn");
            _openBtn.SetSensitive(false);
            _openBtn.OnClicked += (s, e) => OnOpen();

            _discardBtn = Gtk.Button.NewWithLabel("Discard");
            _discardBtn.AddCssClass("screenshot-action-btn");
            _discardBtn.SetSensitive(false);
            _discardBtn.OnClicked += (s, e) => OnDiscard();

            actionBox.Append(_saveAsBtn);
            actionBox.Append(_copyBtn);
            actionBox.Append(_openBtn);
            actionBox.Append(_discardBtn);

            // --- Assemble ---
            mainBox.Append(modeBox);
            mainBox.Append(delayBox);
            mainBox.Append(captureBtn);
            mainBox.Append(previewFrame);
            mainBox.Append(_statusLabel);
            mainBox.Append(actionBox);

            _window.SetChild(mainBox);
        }

        public void Show()
        {
            _window.Present();
        }

        private void SelectMode(CaptureMode mode)
        {
            _selectedMode = mode;
        }

        private async void OnCapture()
        {
            var delay = (int)_delaySpinner.GetValue();
            _statusLabel.SetLabel(delay > 0 ? $"Capturing in {delay}s..." : "Capturing...");

            // Minimize window before capture so it's not in the screenshot
            _window.SetVisible(false);

            // Small delay to let the window hide
            await System.Threading.Tasks.Task.Delay(200);

            var path = await _service.Capture(_selectedMode, delay);

            _window.SetVisible(true);
            _window.Present();

            if (path != null && File.Exists(path))
            {
                _lastCapturePath = path;
                _preview.SetFilename(path);
                _statusLabel.SetLabel($"Saved: {path}");
                SetActionsSensitive(true);
            }
            else
            {
                _statusLabel.SetLabel("Capture failed or cancelled.");
                SetActionsSensitive(false);
            }
        }

        private void SetActionsSensitive(bool sensitive)
        {
            _saveAsBtn.SetSensitive(sensitive);
            _copyBtn.SetSensitive(sensitive);
            _openBtn.SetSensitive(sensitive);
            _discardBtn.SetSensitive(sensitive);
        }

        private async void OnSaveAs()
        {
            if (_lastCapturePath == null) return;

            var dialog = Gtk.FileDialog.New();
            dialog.SetTitle("Save Screenshot");
            dialog.SetInitialName(Path.GetFileName(_lastCapturePath));

            try
            {
                var file = await dialog.SaveAsync(_window);
                if (file != null)
                {
                    var destPath = file.GetPath();
                    if (destPath != null)
                    {
                        await CaptureBackend.SaveToFile(_lastCapturePath, destPath);
                        _statusLabel.SetLabel($"Saved: {destPath}");
                    }
                }
            }
            catch
            {
                // User cancelled the dialog
            }
        }

        private async void OnCopyToClipboard()
        {
            if (_lastCapturePath == null) return;

            var success = await CaptureBackend.CopyToClipboard(_lastCapturePath);
            _statusLabel.SetLabel(success ? "Copied to clipboard!" : "Failed to copy to clipboard.");
        }

        private void OnOpen()
        {
            if (_lastCapturePath == null) return;

            try
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "xdg-open",
                    Arguments = _lastCapturePath,
                    UseShellExecute = false
                });
            }
            catch
            {
                _statusLabel.SetLabel("Failed to open file.");
            }
        }

        private void OnDiscard()
        {
            if (_lastCapturePath != null && File.Exists(_lastCapturePath))
            {
                try { File.Delete(_lastCapturePath); } catch { }
            }

            _lastCapturePath = null;
            _preview.SetFilename(null);
            _statusLabel.SetLabel("Screenshot discarded.");
            SetActionsSensitive(false);
        }
    }
}
