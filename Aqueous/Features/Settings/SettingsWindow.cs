using Aqueous.Bindings.AstalGTK4.Services;
using Aqueous.Features.Settings.SettingsPages;
using Gtk;

namespace Aqueous.Features.Settings
{
    public class SettingsWindow
    {
        private readonly AstalApplication _app;
        private readonly SettingsStore _store;
        private Gtk.Window? _gtkWindow;
        private Gtk.Stack? _stack;
        private Gtk.Box? _sidebarBox;
        private string _activePage = "General";

        public bool IsVisible { get; private set; }

        private static readonly (string Category, (string Name, string Id)[] Pages)[] SidebarLayout =
        [
            ("Shell", [
                ("General", "General"),
                ("Dock", "Dock"),
                ("App Launcher", "App Launcher"),
                ("Snap Zones", "Snap Zones"),
                ("Wallpaper", "Wallpaper"),
            ]),
            ("System", [
                ("Audio", "Audio"),
                ("Bluetooth", "Bluetooth"),
                ("Display", "Display"),
                ("Input", "Input"),
                ("Idle & Lock", "Idle & Lock"),
            ]),
            ("Window Management", [
                ("Decorations", "Decorations"),
                ("Animations", "Animations"),
                ("Move & Resize", "Move & Resize"),
                ("Tiling & Grid", "Tiling & Grid"),
                ("Window Rules", "Window Rules"),
            ]),
            ("Workspaces", [
                ("Workspaces", "Workspaces"),
                ("Cube", "Cube"),
                ("Switcher", "Switcher"),
            ]),
            ("Effects", [
                ("Blur", "Blur"),
                ("Visual Effects", "Visual Effects"),
            ]),
            ("Advanced", [
                ("Core & Commands", "Core & Commands"),
                ("Focus", "Focus"),
                ("Developer Tools", "Developer Tools"),
            ]),
        ];

        public SettingsWindow(AstalApplication app, SettingsStore store)
        {
            _app = app;
            _store = store;
        }

        public void Show()
        {
            if (IsVisible && _gtkWindow != null)
            {
                _gtkWindow.Present();
                return;
            }
            if (IsVisible) return;

            WayfireConfigService.Instance.Load();

            _gtkWindow = Gtk.Window.New();
            _gtkWindow.Title = "Aqueous Settings";
            _gtkWindow.SetDefaultSize(800, 600);
            _gtkWindow.Resizable = true;
            _app.GtkApplication.AddWindow(_gtkWindow);

            _gtkWindow.OnCloseRequest += (_, _) =>
            {
                _gtkWindow = null;
                _stack = null;
                _sidebarBox = null;
                IsVisible = false;
                return false;
            };

            var container = Gtk.Box.New(Orientation.Horizontal, 0);
            container.AddCssClass("settings-window");

            // Sidebar
            _sidebarBox = CreateSidebar();
            var sidebarScroll = Gtk.ScrolledWindow.New();
            sidebarScroll.SetChild(_sidebarBox);
            sidebarScroll.SetPolicy(PolicyType.Never, PolicyType.Automatic);
            sidebarScroll.WidthRequest = 180;
            container.Append(sidebarScroll);

            // Content stack
            _stack = Gtk.Stack.New();
            _stack.AddCssClass("settings-content");
            _stack.Hexpand = true;
            _stack.Vexpand = true;
            _stack.TransitionType = StackTransitionType.SlideUpDown;

            // Shell
            _stack.AddNamed(GeneralPage.Create(_store), "General");
            _stack.AddNamed(DockPage.Create(_store), "Dock");
            _stack.AddNamed(AppLauncherPage.Create(_store), "App Launcher");
            _stack.AddNamed(SnapToPage.Create(_store, _app), "Snap Zones");
            _stack.AddNamed(WallpaperPage.Create(_store), "Wallpaper");

            // System
            _stack.AddNamed(AudioPage.Create(_store), "Audio");
            _stack.AddNamed(BluetoothPage.Create(_store), "Bluetooth");
            _stack.AddNamed(HdrPage.Create(_store), "Display");
            _stack.AddNamed(InputPage.Create(_store), "Input");
            _stack.AddNamed(IdleLockPage.Create(_store), "Idle & Lock");

            // Window Management
            _stack.AddNamed(DecorationsPage.Create(_store), "Decorations");
            _stack.AddNamed(AnimationsPage.Create(_store), "Animations");
            _stack.AddNamed(MoveResizePage.Create(_store), "Move & Resize");
            _stack.AddNamed(TilingGridPage.Create(_store), "Tiling & Grid");
            _stack.AddNamed(WindowRulesPage.Create(_store), "Window Rules");

            // Workspaces
            _stack.AddNamed(WorkspacePage.Create(_store), "Workspaces");
            _stack.AddNamed(CubePage.Create(_store), "Cube");
            _stack.AddNamed(SwitcherPage.Create(_store), "Switcher");

            // Effects
            _stack.AddNamed(BlurPage.Create(_store), "Blur");
            _stack.AddNamed(EffectsPage.Create(_store), "Visual Effects");

            // Advanced
            _stack.AddNamed(CorePage.Create(_store), "Core & Commands");
            _stack.AddNamed(FocusPage.Create(_store), "Focus");
            _stack.AddNamed(DevToolsPage.Create(_store), "Developer Tools");

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
            _gtkWindow.AddController(keyController);

            _gtkWindow.SetChild(container);
            _gtkWindow.Present();
            IsVisible = true;
        }

        public void Hide()
        {
            if (!IsVisible || _gtkWindow == null) return;
            _gtkWindow.Close();
            _gtkWindow = null;
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
            var sidebar = Gtk.Box.New(Orientation.Vertical, 0);
            sidebar.AddCssClass("settings-sidebar");

            foreach (var (category, pages) in SidebarLayout)
            {
                var categoryLabel = Gtk.Label.New(category);
                categoryLabel.AddCssClass("settings-sidebar-category");
                categoryLabel.Halign = Align.Start;
                sidebar.Append(categoryLabel);

                foreach (var (name, id) in pages)
                {
                    var btn = Gtk.Button.New();
                    var label = Gtk.Label.New(name);
                    label.Halign = Align.Start;
                    btn.SetChild(label);
                    btn.AddCssClass("settings-sidebar-item");

                    if (id == _activePage)
                        btn.AddCssClass("active");

                    var pageId = id;
                    btn.OnClicked += (_, _) =>
                    {
                        _activePage = pageId;
                        _stack?.SetVisibleChildName(pageId);
                        RefreshSidebarSelection();
                    };

                    sidebar.Append(btn);
                }
            }

            // Save button at bottom
            var saveBtn = Gtk.Button.NewWithLabel("Save");
            saveBtn.AddCssClass("settings-save-btn");
            saveBtn.MarginTop = 12;
            saveBtn.OnClicked += (_, _) =>
            {
                _store.Save();
                WayfireConfigService.Instance.Save();
                Hide();
            };
            sidebar.Append(saveBtn);

            return sidebar;
        }

        private void RefreshSidebarSelection()
        {
            if (_sidebarBox == null) return;
            var child = _sidebarBox.GetFirstChild();
            while (child != null)
            {
                if (child.GetCssClasses() != null)
                {
                    child.RemoveCssClass("active");
                    // Check if this is a sidebar item button matching active page
                    if (child is Gtk.Button btn)
                    {
                        var btnChild = btn.GetChild();
                        if (btnChild is Gtk.Label lbl && lbl.GetLabel() != null)
                        {
                            // Find matching page id
                            foreach (var (_, pages) in SidebarLayout)
                            {
                                foreach (var (name, id) in pages)
                                {
                                    if (name == lbl.GetLabel() && id == _activePage)
                                    {
                                        child.AddCssClass("active");
                                    }
                                }
                            }
                        }
                    }
                }
                child = child.GetNextSibling();
            }
        }
    }
}
