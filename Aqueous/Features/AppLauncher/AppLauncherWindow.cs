using System;
using System.Diagnostics;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Gtk;

namespace Aqueous.Features.AppLauncher
{
    public class AppLauncherWindow
    {
        private readonly AstalApplication _app;
        private AstalWindow? _window;
        private Gtk.Entry? _searchEntry;
        private Gtk.Box? _resultsList;
        public bool IsVisible { get; private set; }

        public AppLauncherWindow(AstalApplication app)
        {
            _app = app;
        }

        public void Show()
        {
            if (IsVisible) return;

            _window = new AstalWindow();
            _app.GtkApplication.AddWindow(_window.GtkWindow);
            _window.Namespace = "app-launcher";
            _window.Layer = AstalLayer.ASTAL_LAYER_OVERLAY;
            _window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_NORMAL;
            _window.Keymode = AstalKeymode.ASTAL_KEYMODE_EXCLUSIVE;
            _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP;
            _window.MarginTop = 200;

            var container = Gtk.Box.New(Orientation.Vertical, 4);
            container.AddCssClass("launcher-window");

            // Search entry
            _searchEntry = Gtk.Entry.New();
            _searchEntry.AddCssClass("launcher-search");
            _searchEntry.SetPlaceholderText("Search applications...");
            container.Append(_searchEntry);

            // Results list
            _resultsList = Gtk.Box.New(Orientation.Vertical, 2);
            container.Append(_resultsList);

            // Populate initial results
            UpdateResults("");

            // Enter key via Entry's activate signal
            _searchEntry.OnActivate += (sender, args) =>
            {
                LaunchSelected();
            };

            // Text changed handler
            var buffer = _searchEntry.GetBuffer();
            buffer.OnInsertedText += (sender, args) =>
            {
                var text = buffer.GetText();
                UpdateResults(text);
            };
            buffer.OnDeletedText += (sender, args) =>
            {
                var text = buffer.GetText();
                UpdateResults(text);
            };

            // Key handler
            var keyController = Gtk.EventControllerKey.New();
            keyController.OnKeyPressed += (controller, args) =>
            {
                if (args.Keyval == 0xff1b) // Escape
                {
                    Hide();
                    return true;
                }
                if (args.Keyval == 0xff0d) // Return
                {
                    LaunchSelected();
                    return true;
                }
                if (args.Keyval == 0xff52) // Up Arrow
                {
                    if (_selectedIndex > 0)
                    {
                        _selectedIndex--;
                        UpdateSelection();
                    }
                    return true;
                }
                if (args.Keyval == 0xff54) // Down Arrow
                {
                    if (_selectedIndex < _currentResults.Count - 1)
                    {
                        _selectedIndex++;
                        UpdateSelection();
                    }
                    return true;
                }
                return false;
            };
            _window.GtkWindow.AddController(keyController);

            // Key handler on search entry (Entry may capture Return/Escape before window)
            var entryKeyController = Gtk.EventControllerKey.New();
            entryKeyController.OnKeyPressed += (controller, args) =>
            {
                if (args.Keyval == 0xff0d) // Return/Enter
                {
                    LaunchSelected();
                    return true;
                }
                if (args.Keyval == 0xff1b) // Escape
                {
                    Hide();
                    return true;
                }
                return false;
            };
            _searchEntry.AddController(entryKeyController);

            _window.GtkWindow.SetChild(container);
            _window.GtkWindow.Present();
            _searchEntry.GrabFocus();
            IsVisible = true;
        }

        public void Hide()
        {
            if (!IsVisible || _window == null) return;
            _window.GtkWindow.Close();
            _window = null;
            _searchEntry = null;
            _resultsList = null;
            _selectedIndex = 0;
            IsVisible = false;
        }

        private int _selectedIndex;
        private List<DesktopEntry> _currentResults = new();

        private void UpdateResults(string query)
        {
            if (_resultsList == null) return;

            // Clear existing results
            Gtk.Widget? child;
            while ((child = _resultsList.GetFirstChild()) != null)
                _resultsList.Remove(child);

            _currentResults = AppLauncherSearch.Search(query);
            _selectedIndex = 0;

            for (int i = 0; i < _currentResults.Count; i++)
            {
                var entry = _currentResults[i];
                var row = CreateResultRow(entry, i);
                _resultsList.Append(row);
            }

            UpdateSelection();
        }

        private Gtk.Box CreateResultRow(DesktopEntry entry, int index)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 12);
            row.AddCssClass("launcher-result-row");

            var icon = Gtk.Image.NewFromIconName(entry.Icon);
            icon.SetPixelSize(32);
            icon.AddCssClass("launcher-result-icon");
            row.Append(icon);

            var textColumn = Gtk.Box.New(Orientation.Vertical, 0);
            textColumn.Valign = Align.Center;

            var nameLabel = Gtk.Label.New(entry.Name);
            nameLabel.AddCssClass("launcher-result-name");
            nameLabel.Halign = Align.Start;
            textColumn.Append(nameLabel);

            if (!string.IsNullOrEmpty(entry.Comment))
            {
                var commentLabel = Gtk.Label.New(entry.Comment);
                commentLabel.AddCssClass("launcher-result-comment");
                commentLabel.Halign = Align.Start;
                textColumn.Append(commentLabel);
            }

            row.Append(textColumn);

            var gesture = Gtk.GestureClick.New();
            var idx = index;
            gesture.OnReleased += (sender, args) =>
            {
                _selectedIndex = idx;
                LaunchSelected();
            };
            row.AddController(gesture);

            return row;
        }

        private void UpdateSelection()
        {
            if (_resultsList == null) return;

            var child = _resultsList.GetFirstChild();
            int i = 0;
            while (child != null)
            {
                if (i == _selectedIndex)
                    child.AddCssClass("selected");
                else
                    child.RemoveCssClass("selected");
                child = child.GetNextSibling();
                i++;
            }
        }

        private void LaunchSelected()
        {
            if (_selectedIndex < 0 || _selectedIndex >= _currentResults.Count) return;

            var entry = _currentResults[_selectedIndex];
            var exec = AppLauncherSearch.CleanExec(entry.Exec);

            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "/bin/sh",
                    Arguments = $"-c \"{exec}\"",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                });
            }
            catch
            {
                // Ignore launch errors
            }

            Hide();
        }
    }
}
