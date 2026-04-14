using System;
using System.Collections.Generic;
using System.IO;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Gtk;

namespace AqueousGreeter
{
    public record SessionEntry(string Name, string Exec);

    public class GreeterWindow
    {
        private readonly AstalApplication _app;
        private AstalWindow? _window;
        private Gtk.Entry? _usernameEntry;
        private Gtk.PasswordEntry? _passwordEntry;
        private Gtk.DropDown? _sessionDropdown;
        private Gtk.Label? _statusLabel;
        private Gtk.Label? _clockLabel;
        private uint _clockTimer;
        private List<SessionEntry> _sessions = new();

        public event Action<string, string, string>? OnLoginRequested;

        public GreeterWindow(AstalApplication app)
        {
            _app = app;
        }

        public void Show()
        {
            LoadAvailableSessions();

            _window = new AstalWindow();
            _app.GtkApplication.AddWindow(_window.GtkWindow);
            _window.Namespace = "greeter";
            _window.Layer = AstalLayer.ASTAL_LAYER_OVERLAY;
            _window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_EXCLUSIVE;
            _window.Keymode = AstalKeymode.ASTAL_KEYMODE_EXCLUSIVE;
            _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_BOTTOM
                | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT
                | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;

            // Root container
            var overlay = Gtk.Box.New(Orientation.Vertical, 0);
            overlay.AddCssClass("greeter-background");
            overlay.Halign = Align.Fill;
            overlay.Valign = Align.Fill;
            overlay.Hexpand = true;
            overlay.Vexpand = true;

            // Center card
            var card = Gtk.Box.New(Orientation.Vertical, 12);
            card.AddCssClass("greeter-card");
            card.Halign = Align.Center;
            card.Valign = Align.Center;
            card.Hexpand = true;
            card.Vexpand = true;

            // Clock
            _clockLabel = Gtk.Label.New("");
            _clockLabel.AddCssClass("greeter-clock");
            card.Append(_clockLabel);
            UpdateClock();
            _clockTimer = GLib.Functions.TimeoutAdd(0, 1000, () =>
            {
                UpdateClock();
                return true;
            });

            // Hostname
            var hostnameLabel = Gtk.Label.New(Environment.MachineName);
            hostnameLabel.AddCssClass("greeter-hostname");
            card.Append(hostnameLabel);

            // User icon
            var userIcon = Gtk.Image.NewFromIconName("system-users-symbolic");
            userIcon.SetPixelSize(64);
            userIcon.AddCssClass("greeter-icon");
            card.Append(userIcon);

            // Username entry
            _usernameEntry = Gtk.Entry.New();
            _usernameEntry.SetPlaceholderText("Username");
            _usernameEntry.AddCssClass("greeter-username");
            card.Append(_usernameEntry);

            // Password entry
            _passwordEntry = Gtk.PasswordEntry.New();
            _passwordEntry.SetShowPeekIcon(true);
            _passwordEntry.AddCssClass("greeter-password");
            card.Append(_passwordEntry);

            // Key handler on password entry — Enter submits
            var entryKeyController = Gtk.EventControllerKey.New();
            entryKeyController.OnKeyPressed += (controller, args) =>
            {
                if (args.Keyval == 0xff0d) // Return/Enter
                {
                    SubmitLogin();
                    return true;
                }
                return false;
            };
            _passwordEntry.AddController(entryKeyController);

            // Session selector
            if (_sessions.Count > 0)
            {
                var sessionNames = new string[_sessions.Count];
                for (int i = 0; i < _sessions.Count; i++)
                    sessionNames[i] = _sessions[i].Name;

                var stringList = Gtk.StringList.New(sessionNames);
                _sessionDropdown = Gtk.DropDown.New(stringList, null);
                _sessionDropdown.AddCssClass("greeter-session-dropdown");
                card.Append(_sessionDropdown);
            }

            // Login button
            var loginBtn = Gtk.Button.NewWithLabel("Login");
            loginBtn.AddCssClass("greeter-login-button");
            loginBtn.OnClicked += (sender, args) => SubmitLogin();
            card.Append(loginBtn);

            // Status label
            _statusLabel = Gtk.Label.New("");
            _statusLabel.AddCssClass("greeter-status");
            card.Append(_statusLabel);

            // Power buttons row
            var powerRow = Gtk.Box.New(Orientation.Horizontal, 8);
            powerRow.AddCssClass("greeter-power-row");
            powerRow.Halign = Align.Center;

            var shutdownBtn = Gtk.Button.New();
            shutdownBtn.SetIconName("system-shutdown-symbolic");
            shutdownBtn.AddCssClass("greeter-power-button");
            shutdownBtn.SetTooltipText("Shutdown");
            shutdownBtn.OnClicked += (s, e) => PowerAction("poweroff");
            powerRow.Append(shutdownBtn);

            var rebootBtn = Gtk.Button.New();
            rebootBtn.SetIconName("system-reboot-symbolic");
            rebootBtn.AddCssClass("greeter-power-button");
            rebootBtn.SetTooltipText("Reboot");
            rebootBtn.OnClicked += (s, e) => PowerAction("reboot");
            powerRow.Append(rebootBtn);

            var suspendBtn = Gtk.Button.New();
            suspendBtn.SetIconName("system-suspend-symbolic");
            suspendBtn.AddCssClass("greeter-power-button");
            suspendBtn.SetTooltipText("Suspend");
            suspendBtn.OnClicked += (s, e) => PowerAction("suspend");
            powerRow.Append(suspendBtn);

            card.Append(powerRow);

            overlay.Append(card);
            _window.GtkWindow.SetChild(overlay);
            _window.GtkWindow.Present();
            _usernameEntry.GrabFocus();
        }

        public void SetStatus(string message, bool isError)
        {
            if (_statusLabel == null) return;
            _statusLabel.SetText(message);
            _statusLabel.RemoveCssClass("greeter-status-error");
            _statusLabel.RemoveCssClass("greeter-status-info");
            _statusLabel.AddCssClass(isError ? "greeter-status-error" : "greeter-status-info");
        }

        public void ClearPassword()
        {
            if (_passwordEntry == null) return;
            var editable = (Gtk.Editable)_passwordEntry;
            editable.DeleteText(0, -1);
            _passwordEntry.GrabFocus();
        }

        public void SetSensitive(bool sensitive)
        {
            if (_usernameEntry != null) _usernameEntry.SetSensitive(sensitive);
            if (_passwordEntry != null) _passwordEntry.SetSensitive(sensitive);
            if (_sessionDropdown != null) _sessionDropdown.SetSensitive(sensitive);
        }

        private void SubmitLogin()
        {
            if (_usernameEntry == null || _passwordEntry == null) return;

            var username = _usernameEntry.GetText();
            var editable = (Gtk.Editable)_passwordEntry;
            var password = editable.GetText();

            if (string.IsNullOrEmpty(username) || string.IsNullOrEmpty(password))
            {
                SetStatus("Please enter username and password.", true);
                return;
            }

            var sessionCmd = "bash";
            if (_sessionDropdown != null && _sessions.Count > 0)
            {
                var idx = (int)_sessionDropdown.GetSelected();
                if (idx >= 0 && idx < _sessions.Count)
                    sessionCmd = _sessions[idx].Exec;
            }

            OnLoginRequested?.Invoke(username, password, sessionCmd);
        }

        private void UpdateClock()
        {
            if (_clockLabel == null) return;
            var now = DateTime.Now;
            _clockLabel.SetText(now.ToString("h:mm tt\ndddd, MMMM d"));
        }

        private void LoadAvailableSessions()
        {
            _sessions.Clear();
            var dirs = new[] { "/usr/share/wayland-sessions", "/usr/share/xsessions" };
            foreach (var dir in dirs)
            {
                if (!Directory.Exists(dir)) continue;
                foreach (var file in Directory.GetFiles(dir, "*.desktop"))
                {
                    var name = ParseDesktopEntry(file, "Name");
                    var exec = ParseDesktopEntry(file, "Exec");
                    if (name != null && exec != null)
                        _sessions.Add(new SessionEntry(name, exec));
                }
            }
        }

        private static string? ParseDesktopEntry(string path, string key)
        {
            foreach (var line in File.ReadLines(path))
            {
                var trimmed = line.Trim();
                if (trimmed.StartsWith(key + "=", StringComparison.Ordinal))
                    return trimmed.Substring(key.Length + 1).Trim();
            }
            return null;
        }

        private static void PowerAction(string action)
        {
            try
            {
                System.Diagnostics.Process.Start("systemctl", action);
            }
            catch
            {
                // Ignore — greeter user may not have permission
            }
        }
    }
}
