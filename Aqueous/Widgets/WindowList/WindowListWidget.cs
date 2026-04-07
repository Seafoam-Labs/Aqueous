using System;
using System.Linq;
using Aqueous.Features.SnapTo;
using Aqueous.Features.WindowManager;

namespace Aqueous.Widgets.WindowList
{
    public class WindowListWidget
    {
        private readonly WindowManagerService _windowManager;
        private readonly Gtk.Button _button;
        private readonly Gtk.Label _label;
        private Gtk.Popover? _popover;

        public Gtk.Button Button => _button;

        public WindowListWidget(WindowManagerService windowManager)
        {
            _windowManager = windowManager;

            _label = Gtk.Label.New("No window");
            _label.AddCssClass("window-list-label");
            _label.SetEllipsize(Pango.EllipsizeMode.End);
            _label.SetMaxWidthChars(40);

            _button = Gtk.Button.New();
            _button.SetChild(_label);
            _button.AddCssClass("window-list-button");
            _button.OnClicked += OnButtonClicked;

            _windowManager.WindowFocused += OnWindowFocused;
            _windowManager.WindowsChanged += OnWindowsChanged;

            UpdateLabel();
        }

        private void OnWindowFocused(TopLevelWindow win)
        {
            _label.SetLabel(string.IsNullOrEmpty(win.Title) ? win.AppId : win.Title);
        }

        private void OnWindowsChanged()
        {
            UpdateLabel();
        }

        private void UpdateLabel()
        {
            var focused = _windowManager.FocusedWindow;
            if (focused != null)
                _label.SetLabel(string.IsNullOrEmpty(focused.Title) ? focused.AppId : focused.Title);
            else
                _label.SetLabel("No window");
        }

        private void OnButtonClicked(Gtk.Button sender, EventArgs e)
        {
            if (_popover != null)
            {
                _popover.Popdown();
                _popover = null;
                return;
            }

            var windows = _windowManager.Windows
                .Where(w => w.Role == "toplevel")
                .ToList();

            if (windows.Count == 0) return;

            var box = Gtk.Box.New(Gtk.Orientation.Vertical, 4);
            box.AddCssClass("window-list-popup");
            box.SetMarginTop(8);
            box.SetMarginBottom(8);
            box.SetMarginStart(8);
            box.SetMarginEnd(8);

            foreach (var win in windows)
            {
                var row = Gtk.Box.New(Gtk.Orientation.Horizontal, 8);
                row.AddCssClass("window-list-row");

                var icon = Gtk.Image.NewFromIconName(
                    string.IsNullOrEmpty(win.AppId) ? "application-x-executable" : win.AppId);
                icon.SetPixelSize(24);
                row.Append(icon);

                var title = Gtk.Label.New(string.IsNullOrEmpty(win.Title) ? win.AppId : win.Title);
                title.SetEllipsize(Pango.EllipsizeMode.End);
                title.SetMaxWidthChars(30);
                title.SetHexpand(true);
                title.SetXalign(0);
                row.Append(title);

                if (win.Minimized)
                {
                    var minLabel = Gtk.Label.New("(minimized)");
                    minLabel.AddCssClass("window-list-minimized");
                    row.Append(minLabel);
                }

                if (win.Focused)
                    row.AddCssClass("window-list-row-focused");

                var focusBtn = Gtk.Button.New();
                focusBtn.SetChild(row);
                focusBtn.AddCssClass("window-list-item-button");
                var viewId = win.Id;
                focusBtn.OnClicked += (_, _) =>
                {
                    _ = WayfireIpc.FocusView(viewId);
                    _popover?.Popdown();
                    _popover = null;
                };

                var closeBtn = Gtk.Button.NewFromIconName("window-close-symbolic");
                closeBtn.AddCssClass("window-list-close-button");
                var closeId = win.Id;
                closeBtn.OnClicked += (_, _) =>
                {
                    _ = WayfireIpc.CloseView(closeId);
                };

                var itemBox = Gtk.Box.New(Gtk.Orientation.Horizontal, 4);
                itemBox.Append(focusBtn);
                itemBox.Append(closeBtn);
                box.Append(itemBox);
            }

            _popover = Gtk.Popover.New();
            _popover.SetChild(box);
            _popover.SetParent(_button);
            _popover.Popup();
        }
    }
}
