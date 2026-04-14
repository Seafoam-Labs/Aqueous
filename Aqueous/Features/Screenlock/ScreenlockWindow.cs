using System;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Gtk;

namespace Aqueous.Features.Screenlock
{
    public class ScreenlockWindow
    {
        private readonly AstalApplication _app;
        private AstalWindow? _window;
        private Gtk.PasswordEntry? _passwordEntry;
        private Gtk.Label? _statusLabel;
        private Gtk.Label? _clockLabel;
        private uint _clockTimer;

        public bool IsVisible { get; private set; }

        public event Action<string>? OnPasswordSubmitted;

        public ScreenlockWindow(AstalApplication app)
        {
            _app = app;
        }

        public void Show()
        {
            if (IsVisible) return;

            _window = new AstalWindow();
            _app.GtkApplication.AddWindow(_window.GtkWindow);
            _window.Namespace = "screenlock";
            _window.Layer = AstalLayer.ASTAL_LAYER_OVERLAY;
            _window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_EXCLUSIVE;
            _window.Keymode = AstalKeymode.ASTAL_KEYMODE_EXCLUSIVE;
            _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_BOTTOM
                | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT
                | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;

            // Root overlay container
            var overlay = Gtk.Box.New(Orientation.Vertical, 0);
            overlay.AddCssClass("screenlock-background");
            overlay.Halign = Align.Fill;
            overlay.Valign = Align.Fill;
            overlay.Hexpand = true;
            overlay.Vexpand = true;

            // Center card
            var card = Gtk.Box.New(Orientation.Vertical, 16);
            card.AddCssClass("screenlock-card");
            card.Halign = Align.Center;
            card.Valign = Align.Center;
            card.Hexpand = true;
            card.Vexpand = true;

            // Clock
            _clockLabel = Gtk.Label.New("");
            _clockLabel.AddCssClass("screenlock-clock");
            card.Append(_clockLabel);
            UpdateClock();
            _clockTimer = GLib.Functions.TimeoutAdd(0, 1000, () =>
            {
                UpdateClock();
                return true;
            });

            // User icon
            var userIcon = Gtk.Image.NewFromIconName("system-lock-screen-symbolic");
            userIcon.SetPixelSize(64);
            userIcon.AddCssClass("screenlock-icon");
            card.Append(userIcon);

            // Username label
            var userLabel = Gtk.Label.New(Environment.UserName);
            userLabel.AddCssClass("screenlock-username");
            card.Append(userLabel);

            // Password entry
            _passwordEntry = Gtk.PasswordEntry.New();
            _passwordEntry.AddCssClass("screenlock-password");
            _passwordEntry.SetShowPeekIcon(true);
            card.Append(_passwordEntry);

            // Key handler on password entry
            var entryKeyController = Gtk.EventControllerKey.New();
            entryKeyController.OnKeyPressed += (controller, args) =>
            {
                if (args.Keyval == 0xff0d) // Return/Enter
                {
                    SubmitPassword();
                    return true;
                }
                return false;
            };
            _passwordEntry.AddController(entryKeyController);

            // Unlock button
            var unlockBtn = Gtk.Button.NewWithLabel("Unlock");
            unlockBtn.AddCssClass("screenlock-unlock-btn");
            unlockBtn.OnClicked += (sender, args) => SubmitPassword();
            card.Append(unlockBtn);

            // Status label
            _statusLabel = Gtk.Label.New("");
            _statusLabel.AddCssClass("screenlock-status");
            card.Append(_statusLabel);

            overlay.Append(card);
            _window.GtkWindow.SetChild(overlay);
            _window.GtkWindow.Present();
            _passwordEntry.GrabFocus();
            IsVisible = true;
        }

        public void Hide()
        {
            if (!IsVisible || _window == null) return;

            if (_clockTimer != 0)
            {
                GLib.Functions.SourceRemove(_clockTimer);
                _clockTimer = 0;
            }

            _window.GtkWindow.Close();
            _window = null;
            _passwordEntry = null;
            _statusLabel = null;
            _clockLabel = null;
            IsVisible = false;
        }

        public void SetStatus(string message, bool isError)
        {
            if (_statusLabel == null) return;
            _statusLabel.SetText(message);
            _statusLabel.RemoveCssClass("screenlock-status-error");
            _statusLabel.RemoveCssClass("screenlock-status-info");
            _statusLabel.AddCssClass(isError ? "screenlock-status-error" : "screenlock-status-info");
        }

        public void ClearPassword()
        {
            if (_passwordEntry == null) return;
            // PasswordEntry uses the Editable interface
            var editable = (Gtk.Editable)_passwordEntry;
            editable.DeleteText(0, -1);
            _passwordEntry.GrabFocus();
        }

        public void SetSensitive(bool sensitive)
        {
            if (_passwordEntry != null) _passwordEntry.SetSensitive(sensitive);
        }

        private void SubmitPassword()
        {
            if (_passwordEntry == null) return;
            var editable = (Gtk.Editable)_passwordEntry;
            var password = editable.GetText();
            if (!string.IsNullOrEmpty(password))
            {
                OnPasswordSubmitted?.Invoke(password);
            }
        }

        private void UpdateClock()
        {
            if (_clockLabel == null) return;
            var now = DateTime.Now;
            _clockLabel.SetText(now.ToString("h:mm tt\ndddd, MMMM d"));
        }
    }
}
