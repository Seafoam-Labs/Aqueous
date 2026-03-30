using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Aqueous.Features.Settings.SettingsPages;
using Gtk;

namespace Aqueous.Features.Settings
{
    public class SettingsWindow
    {
        private readonly AstalApplication _app;
        private readonly SettingsStore _store;
        private AstalWindow? _window;
        private Gtk.Stack? _stack;
        private Gtk.Box? _sidebarBox;
        private string _activePage = "General";

        public bool IsVisible { get; private set; }

        public SettingsWindow(AstalApplication app, SettingsStore store)
        {
            _app = app;
            _store = store;
        }

        public void Show()
        {
            if (IsVisible) return;

            _window = new AstalWindow();
            _app.GtkApplication.AddWindow(_window.GtkWindow);
            _window.Namespace = "settings";
            _window.Layer = AstalLayer.ASTAL_LAYER_TOP;
            _window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_NORMAL;
            _window.Keymode = AstalKeymode.ASTAL_KEYMODE_ON_DEMAND;

            _window.GtkWindow.SetDefaultSize(700, 500);

            var container = Gtk.Box.New(Orientation.Horizontal, 0);
            container.AddCssClass("settings-window");

            // Sidebar
            _sidebarBox = CreateSidebar();
            container.Append(_sidebarBox);

            // Content stack
            _stack = Gtk.Stack.New();
            _stack.AddCssClass("settings-content");
            _stack.Hexpand = true;
            _stack.Vexpand = true;
            _stack.TransitionType = StackTransitionType.SlideUpDown;

            _stack.AddNamed(GeneralPage.Create(_store), "General");
            _stack.AddNamed(SnapToPage.Create(_store), "Snap Zones");
            _stack.AddNamed(AudioPage.Create(_store), "Audio");
            _stack.AddNamed(AppLauncherPage.Create(_store), "App Launcher");
            _stack.AddNamed(BluetoothPage.Create(_store), "Bluetooth");

            _stack.SetVisibleChildName(_activePage);

            var scrolled = Gtk.ScrolledWindow.New();
            scrolled.SetChild(_stack);
            scrolled.Hexpand = true;
            scrolled.Vexpand = true;
            scrolled.SetPolicy(PolicyType.Never, PolicyType.Automatic);
            container.Append(scrolled);

            // Escape key
            var keyController = Gtk.EventControllerKey.New();
            keyController.OnKeyPressed += (controller, args) =>
            {
                if (args.Keyval == 0xff1b)
                {
                    Hide();
                    return true;
                }
                return false;
            };
            _window.GtkWindow.AddController(keyController);

            // Close on focus loss
            _window.GtkWindow.OnNotify += (sender, args) =>
            {
                if (args.Pspec.GetName() == "is-active" && !_window.GtkWindow.IsActive)
                    Hide();
            };

            _window.GtkWindow.SetChild(container);
            _window.GtkWindow.Present();
            IsVisible = true;
        }

        public void Hide()
        {
            if (!IsVisible || _window == null) return;
            _window.GtkWindow.Close();
            _window = null;
            _stack = null;
            _sidebarBox = null;
            IsVisible = false;
        }

        public void Toggle()
        {
            if (IsVisible) Hide();
            else Show();
        }

        private Gtk.Box CreateSidebar()
        {
            var sidebar = Gtk.Box.New(Orientation.Vertical, 2);
            sidebar.AddCssClass("settings-sidebar");

            string[] pages = ["General", "Snap Zones", "Audio", "App Launcher", "Bluetooth"];
            foreach (var page in pages)
            {
                var btn = Gtk.Button.New();
                var label = Gtk.Label.New(page);
                label.Halign = Align.Start;
                btn.SetChild(label);

                if (page == _activePage)
                    btn.AddCssClass("active");

                var pageName = page;
                btn.OnClicked += (_, _) =>
                {
                    _activePage = pageName;
                    _stack?.SetVisibleChildName(pageName);
                    RefreshSidebarSelection();
                };

                sidebar.Append(btn);
            }

            return sidebar;
        }

        private void RefreshSidebarSelection()
        {
            if (_sidebarBox == null) return;
            var child = _sidebarBox.GetFirstChild();
            string[] pages = ["General", "Snap Zones", "Audio", "App Launcher", "Bluetooth"];
            int i = 0;
            while (child != null)
            {
                if (i < pages.Length)
                {
                    if (pages[i] == _activePage)
                        child.AddCssClass("active");
                    else
                        child.RemoveCssClass("active");
                }
                child = child.GetNextSibling();
                i++;
            }
        }
    }
}
