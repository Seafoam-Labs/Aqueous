using System;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Gtk;

namespace Aqueous.Features.Calendar;

public class CalendarPopup
{
    private readonly AstalApplication _app;
    private AstalWindow? _window;
    public bool IsVisible { get; private set; }

    public CalendarPopup(AstalApplication app)
    {
        _app = app;
    }

    public void Toggle()
    {
        if (IsVisible) Hide();
        else Show();
    }

    public void Show()
    {
        if (IsVisible) return;

        _window = new AstalWindow();
        _app.GtkApplication.AddWindow(_window.GtkWindow);
        _window.Namespace = "calendar-popup";
        _window.Layer = AstalLayer.ASTAL_LAYER_OVERLAY;
        _window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_IGNORE;
        _window.Keymode = AstalKeymode.ASTAL_KEYMODE_EXCLUSIVE;
        _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                       | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;

        var container = Box.New(Orientation.Vertical, 8);
        container.AddCssClass("calendar-popup");

        // Current date/time header
        var header = Label.New(DateTime.Now.ToString("dddd, MMMM d, yyyy"));
        header.AddCssClass("calendar-header");
        container.Append(header);

        // GTK Calendar widget
        var calendar = Gtk.Calendar.New();
        calendar.AddCssClass("calendar-widget");
        container.Append(calendar);

        // Escape key to dismiss
        var keyController = EventControllerKey.New();
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
        IsVisible = false;
    }
}
