using System;
using System.Collections.Generic;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Aqueous.Helpers;
using Gtk;

namespace Aqueous.Features.ClipboardManager
{
    public class ClipboardPopup
    {
        private readonly AstalApplication _app;
        private AstalWindow? _window;
        private Gtk.ListBox? _listBox;
        private List<ClipboardEntry> _entries = new();
        private string _filterText = "";
        public bool IsVisible { get; private set; }

        public ClipboardPopup(AstalApplication app)
        {
            _app = app;
        }

        public async void Show(Gtk.Button? anchorButton = null)
        {
            if (IsVisible) return;

            _entries = await ClipboardBackend.GetClipboardHistoryAsync(50);

            _window = new AstalWindow();
            _app.GtkApplication.AddWindow(_window.GtkWindow);
            _window.Namespace = "clipboard-manager";
            _window.Layer = AstalLayer.ASTAL_LAYER_OVERLAY;
            _window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_IGNORE;
            _window.Keymode = AstalKeymode.ASTAL_KEYMODE_EXCLUSIVE;

            var container = Gtk.Box.New(Orientation.Vertical, 8);
            container.AddCssClass("clipboard-manager");

            // Header
            var header = Gtk.Label.New("Clipboard History");
            header.AddCssClass("clipboard-header");
            header.Halign = Align.Start;
            container.Append(header);

            // Search entry
            var searchEntry = Gtk.SearchEntry.New();
            searchEntry.SetPlaceholderText("Filter clipboard...");
            searchEntry.AddCssClass("clipboard-search");
            searchEntry.OnSearchChanged += (sender, args) =>
            {
                _filterText = searchEntry.GetText() ?? "";
                FilterEntries();
            };
            container.Append(searchEntry);

            // List box
            _listBox = Gtk.ListBox.New();
            _listBox.AddCssClass("clipboard-list");
            _listBox.SetSelectionMode(SelectionMode.None);
            PopulateList();

            var scrolled = Gtk.ScrolledWindow.New();
            scrolled.SetPolicy(PolicyType.Never, PolicyType.Automatic);
            scrolled.SetMaxContentHeight(400);
            scrolled.SetPropagateNaturalHeight(true);
            scrolled.SetChild(_listBox);
            container.Append(scrolled);

            // Clear all button
            var clearBtn = Gtk.Button.NewWithLabel("Clear All");
            clearBtn.AddCssClass("clipboard-clear-btn");
            clearBtn.OnClicked += async (sender, args) =>
            {
                await ClipboardBackend.ClearHistoryAsync();
                _entries.Clear();
                PopulateList();
            };
            container.Append(clearBtn);

            if (anchorButton != null)
            {
                var (x, y) = WidgetGeometryHelper.GetWidgetGlobalPos(anchorButton);
                var (screenWidth, screenHeight) = WidgetGeometryHelper.GetScreenSize();

                container.Measure(Orientation.Horizontal, -1, out _, out var natWidth, out _, out _);
                container.Measure(Orientation.Vertical, -1, out _, out var natHeight, out _, out _);

                var popupWidth = Math.Max(350, natWidth);
                var popupHeight = Math.Min(450, natHeight);

                _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT;

                var targetX = x + (anchorButton.GetAllocatedWidth() / 2) - (popupWidth / 2);
                var targetY = y + anchorButton.GetAllocatedHeight() + 4; // Tiny gap

                // Keep it on screen
                if (targetX + popupWidth > screenWidth - 10) targetX = screenWidth - popupWidth - 10;
                if (targetX < 10) targetX = 10;

                if (targetY + popupHeight > screenHeight - 10)
                {
                    targetY = Math.Max(10, y - popupHeight - 4);
                }

                _window.MarginLeft = targetX;
                _window.MarginTop = targetY;
            }
            else
            {
                _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                               | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;
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

            _window.GtkWindow.SetChild(container);
            _window.GtkWindow.Present();
            IsVisible = true;
        }

        public void Hide()
        {
            if (!IsVisible || _window == null) return;
            _window.GtkWindow.Close();
            _window = null;
            _listBox = null;
            IsVisible = false;
        }

        private void PopulateList()
        {
            if (_listBox == null) return;

            // Remove all existing children
            while (_listBox.GetFirstChild() != null)
            {
                var child = _listBox.GetFirstChild()!;
                _listBox.Remove(child);
            }

            foreach (var entry in _entries)
            {
                if (!string.IsNullOrEmpty(_filterText) &&
                    !entry.Content.Contains(_filterText, StringComparison.OrdinalIgnoreCase))
                    continue;

                var row = CreateEntryRow(entry);
                _listBox.Append(row);
            }
        }

        private void FilterEntries()
        {
            PopulateList();
        }

        private Gtk.Box CreateEntryRow(ClipboardEntry entry)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("clipboard-entry-row");

            // Content preview button (click to paste)
            var contentBtn = Gtk.Button.New();
            contentBtn.Hexpand = true;
            contentBtn.AddCssClass("clipboard-entry");

            var preview = entry.IsImage
                ? "[Image]"
                : Truncate(entry.Content, 80);

            var label = Gtk.Label.New(preview);
            label.Halign = Align.Start;
            label.SetEllipsize(Pango.EllipsizeMode.End);
            label.SetMaxWidthChars(80);
            contentBtn.SetChild(label);

            contentBtn.OnClicked += async (sender, args) =>
            {
                await ClipboardBackend.PasteEntryAsync(entry.Id);
                Hide();
            };

            // Delete button
            var deleteBtn = Gtk.Button.NewFromIconName("edit-delete-symbolic");
            deleteBtn.AddCssClass("clipboard-delete-btn");
            deleteBtn.OnClicked += async (sender, args) =>
            {
                await ClipboardBackend.DeleteEntryAsync(entry.Id);
                _entries.Remove(entry);
                PopulateList();
            };

            row.Append(contentBtn);
            row.Append(deleteBtn);
            return row;
        }

        private static string Truncate(string text, int maxLength)
        {
            // Replace newlines with spaces for single-line preview
            var singleLine = text.Replace('\n', ' ').Replace('\r', ' ');
            return singleLine.Length <= maxLength
                ? singleLine
                : singleLine[..maxLength] + "…";
        }
    }
}
