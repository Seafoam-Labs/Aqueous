using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Aqueous.Features.AppLauncher;
using Aqueous.Features.Settings;
using Gtk;

namespace Aqueous.Widgets.StartMenu;

public class StartMenuWindow
{
    private readonly AstalApplication _app;
    private readonly SettingsService _settingsService;
    private AstalWindow? _window;
    private Gtk.Entry? _searchEntry;
    private Gtk.Box? _contentArea;
    private Gtk.Box? _sidebarBox;
    private string _activeTab = "Favorites";
    private StartMenuConfig _config;

    public bool IsVisible { get; private set; }

    public StartMenuWindow(AstalApplication app, SettingsService settingsService)
    {
        _app = app;
        _settingsService = settingsService;
        _config = StartMenuConfig.Load();
    }

    public void Toggle(double? x = null, double? y = null)
    {
        if (IsVisible)
            Hide();
        else
            Show(x, y);
    }

    public void Show(double? x = null, double? y = null)
    {
        if (IsVisible) return;

        _config = StartMenuConfig.Load();
        AppDiscoveryService.Refresh();

        EnsureWindowCreated();

        if (x.HasValue && _window != null)
        {
            // Window width is 510
            int menuWidth = 510;
            // Center under the button: buttonX - (menuWidth / 2)
            // Note: The caller should ideally pass the button's center X, but if it passes the button's left X, 
            // we might need button width. For now, let's assume 'x' is where we want the left edge, 
            // or we can try to center it if we know the button width.
            // Let's just align to the button's left edge for now as a starting point, 
            // but add a small offset to not be perfectly on the edge if needed.
            
            int marginLeft = (int)x.Value;
            
            // Screen boundary check (assuming common 1920 width if we can't get it, 
            // but let's just make sure it's not negative)
            if (marginLeft < 4) marginLeft = 4;
            
            _window.MarginLeft = marginLeft;
        }

        RefreshSidebarSelection();
        PopulateContent();

        _window!.GtkWindow.SetVisible(true);
        _window.GtkWindow.Present();
        IsVisible = true;
    }

    private void EnsureWindowCreated()
    {
        if (_window != null) return;

        _window = new AstalWindow();
        _app.GtkApplication.AddWindow(_window.GtkWindow);
        _window.Namespace = "start-menu";
        _window.Layer = AstalLayer.ASTAL_LAYER_TOP;
        _window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_NORMAL;
        _window.Keymode = AstalKeymode.ASTAL_KEYMODE_ON_DEMAND;
        _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                       | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT;
        _window.MarginTop = 40;
        _window.MarginLeft = 4;

        _window.GtkWindow.SetDefaultSize(510, 540);

        var container = Gtk.Box.New(Orientation.Vertical, 0);
        container.AddCssClass("start-menu-window");

        // Header: user info
        var header = CreateHeader();
        container.Append(header);

        // Search bar
        _searchEntry = Gtk.Entry.New();
        _searchEntry.AddCssClass("start-menu-search");
        _searchEntry.SetPlaceholderText("Search applications...");
        container.Append(_searchEntry);

        // Main body: sidebar + content
        var body = Gtk.Box.New(Orientation.Horizontal, 0);
        body.AddCssClass("start-menu-body");
        body.Vexpand = true;

        _sidebarBox = CreateSidebar();
        body.Append(_sidebarBox);

        _contentArea = Gtk.Box.New(Orientation.Vertical, 4);
        _contentArea.AddCssClass("start-menu-content");
        _contentArea.Hexpand = true;
        _contentArea.Vexpand = true;

        var scrolled = Gtk.ScrolledWindow.New();
        scrolled.SetChild(_contentArea);
        scrolled.Hexpand = true;
        scrolled.Vexpand = true;
        scrolled.SetPolicy(PolicyType.Never, PolicyType.Automatic);
        body.Append(scrolled);

        container.Append(body);

        // Footer: power actions
        var footer = CreateFooter();
        container.Append(footer);

        // Wire search
        var buffer = _searchEntry.GetBuffer();
        buffer.OnInsertedText += (_, _) => OnSearchChanged(buffer.GetText());
        buffer.OnDeletedText += (_, _) => OnSearchChanged(buffer.GetText());

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
        var focusController = Gtk.EventControllerFocus.New();
        focusController.OnLeave += (_, _) => Hide();
        _window.GtkWindow.AddController(focusController);

        // Also watch is-active for layer-shell reliability
        _window.GtkWindow.OnNotify += (sender, args) =>
        {
            if (args.Pspec.GetName() == "is-active" && !_window.GtkWindow.IsActive)
                Hide();
        };

        _window.GtkWindow.SetChild(container);
    }

    public void Hide()
    {
        if (!IsVisible || _window == null) return;
        _searchEntry?.GetBuffer().SetText("", 0);
        _activeTab = "Favorites";
        _window.GtkWindow.SetVisible(false);
        IsVisible = false;
    }

    private Gtk.Box CreateHeader()
    {
        var header = Gtk.Box.New(Orientation.Horizontal, 8);
        header.AddCssClass("start-menu-header");

        var username = Environment.GetEnvironmentVariable("USER") ?? "User";
        var avatar = Gtk.Label.New("A");
        avatar.AddCssClass("start-menu-avatar");

        var nameLabel = Gtk.Label.New(username);
        nameLabel.AddCssClass("start-menu-username");

        header.Append(avatar);
        header.Append(nameLabel);
        return header;
    }

    private Gtk.Box CreateSidebar()
    {
        var sidebar = Gtk.Box.New(Orientation.Vertical, 2);
        sidebar.AddCssClass("start-menu-sidebar");

        string[] tabs = ["Favorites", "All Apps", "Categories"];
        foreach (var tab in tabs)
        {
            var btn = Gtk.Button.New();
            var label = Gtk.Label.New(tab);
            label.Halign = Align.Start;
            btn.SetChild(label);
            btn.AddCssClass("start-menu-sidebar-btn");
            if (tab == _activeTab)
                btn.AddCssClass("active");

            var tabName = tab;
            btn.OnClicked += (_, _) =>
            {
                _activeTab = tabName;
                RefreshSidebarSelection();
                PopulateContent();
            };

            sidebar.Append(btn);
        }

        return sidebar;
    }

    private void RefreshSidebarSelection()
    {
        if (_sidebarBox == null) return;
        var child = _sidebarBox.GetFirstChild();
        string[] tabs = ["Favorites", "All Apps", "Categories"];
        int i = 0;
        while (child != null)
        {
            if (i < tabs.Length)
            {
                if (tabs[i] == _activeTab)
                    child.AddCssClass("active");
                else
                    child.RemoveCssClass("active");
            }
            child = child.GetNextSibling();
            i++;
        }
    }

    private Gtk.Box CreateFooter()
    {
        var footer = Gtk.Box.New(Orientation.Horizontal, 8);
        footer.AddCssClass("start-menu-footer");

        var settingsBtn = Gtk.Button.New();
        settingsBtn.SetChild(Gtk.Label.New("Settings"));
        settingsBtn.AddCssClass("start-menu-power-btn");
        settingsBtn.OnClicked += (_, _) =>
        {
            Hide();
            _settingsService.Toggle();
        };

        var powerBtn = CreateFooterButton("Power Off", "systemctl poweroff");
        var restartBtn = CreateFooterButton("Restart", "systemctl reboot");
        var lockBtn = CreateFooterButton("Lock", "loginctl lock-session");
        var logoutBtn = CreateFooterButton("Logout", "loginctl terminate-session self || killall wayfire");

        footer.Append(settingsBtn);
        footer.Append(powerBtn);
        footer.Append(restartBtn);
        footer.Append(lockBtn);
        footer.Append(logoutBtn);

        return footer;
    }

    private Gtk.Button CreateFooterButton(string label, string command)
    {
        var btn = Gtk.Button.New();
        btn.SetChild(Gtk.Label.New(label));
        btn.AddCssClass("start-menu-power-btn");
        btn.OnClicked += (_, _) =>
        {
            Hide();
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "/bin/sh",
                    Arguments = $"-c \"{command}\"",
                    UseShellExecute = false,
                });
            }
            catch { }
        };
        return btn;
    }

    private void OnSearchChanged(string query)
    {
        if (string.IsNullOrWhiteSpace(query))
        {
            PopulateContent();
            return;
        }

        var results = AppDiscoveryService.Search(query);
        ClearContent();
        foreach (var entry in results.Take(20))
            _contentArea?.Append(CreateAppRow(entry));
    }

    private void PopulateContent()
    {
        ClearContent();
        if (_contentArea == null) return;

        switch (_activeTab)
        {
            case "Favorites":
                PopulateFavorites();
                break;
            case "All Apps":
                PopulateAllApps();
                break;
            case "Categories":
                PopulateCategories();
                break;
        }
    }

    private void PopulateFavorites()
    {
        if (_contentArea == null) return;
        var allEntries = AppDiscoveryService.GetEntries();
        var favNames = _config.Favorites;

        if (favNames.Count == 0)
        {
            var hint = Gtk.Label.New("No favorites yet. Browse All Apps to find applications.");
            hint.AddCssClass("start-menu-hint");
            _contentArea.Append(hint);
            return;
        }

        foreach (var favName in favNames)
        {
            var entry = allEntries.FirstOrDefault(e =>
                e.Name.Equals(favName, StringComparison.OrdinalIgnoreCase));
            if (entry != null)
                _contentArea.Append(CreateAppRow(entry));
        }
    }

    private void PopulateAllApps()
    {
        if (_contentArea == null) return;
        foreach (var entry in AppDiscoveryService.GetEntries())
            _contentArea.Append(CreateAppRow(entry));
    }

    private void PopulateCategories()
    {
        if (_contentArea == null) return;
        var categories = AppDiscoveryService.GetByCategory();
        foreach (var (category, entries) in categories)
        {
            var catLabel = Gtk.Label.New(category);
            catLabel.AddCssClass("start-menu-category-header");
            catLabel.Halign = Align.Start;
            _contentArea.Append(catLabel);

            foreach (var entry in entries)
                _contentArea.Append(CreateAppRow(entry));
        }
    }

    private Gtk.Box CreateAppRow(AppDiscoveryService.CategorizedEntry entry)
    {
        // 1. Create a horizontal box for the main row
        var row = Gtk.Box.New(Orientation.Horizontal, 12);
        row.AddCssClass("start-menu-app-row");

        // 2. Create and add the icon widget
        var icon = Gtk.Image.NewFromIconName(entry.Icon);
        icon.SetPixelSize(32);
        icon.AddCssClass("start-menu-app-icon");
        row.Append(icon);

        // 3. Create a vertical box for the text labels
        var textColumn = Gtk.Box.New(Orientation.Vertical, 0);
        textColumn.Valign = Align.Center;

        var nameLabel = Gtk.Label.New(entry.Name);
        nameLabel.AddCssClass("start-menu-app-name");
        nameLabel.Halign = Align.Start;
        textColumn.Append(nameLabel);

        if (!string.IsNullOrEmpty(entry.Comment))
        {
            var commentLabel = Gtk.Label.New(entry.Comment);
            commentLabel.AddCssClass("start-menu-app-comment");
            commentLabel.Halign = Align.Start;
            textColumn.Append(commentLabel);
        }

        // 4. Append the text column to the row
        row.Append(textColumn);

        // 5. Existing gesture logic
        var gesture = Gtk.GestureClick.New();
        gesture.OnReleased += (_, _) => LaunchApp(entry);
        row.AddController(gesture);

        return row;
    }

    private void LaunchApp(AppDiscoveryService.CategorizedEntry entry)
    {
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
        catch { }

        Hide();
    }

    private void ClearContent()
    {
        if (_contentArea == null) return;
        Gtk.Widget? child;
        while ((child = _contentArea.GetFirstChild()) != null)
            _contentArea.Remove(child);
    }
}
