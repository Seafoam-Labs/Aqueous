using System;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Aqueous.Helpers;
using Gtk;

namespace Aqueous.Features.Calendar;

public class CalendarPopup
{
    private readonly AstalApplication _app;
    private AstalWindow? _window;
    private AstalWindow? _backdrop;
    public bool IsVisible { get; private set; }

    public CalendarPopup(AstalApplication app)
    {
        _app = app;
    }

    public void Toggle(Gtk.Button? anchorButton = null)
    {
        if (IsVisible) Hide();
        else Show(anchorButton);
    }

    public void Show(Gtk.Button? anchorButton = null)
    {
        if (IsVisible) return;

        _window = new AstalWindow();
        _app.GtkApplication.AddWindow(_window.GtkWindow);
        _window.Namespace = "calendar-popup";
        _window.Layer = AstalLayer.ASTAL_LAYER_OVERLAY;
        _window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_IGNORE;
        _window.Keymode = AstalKeymode.ASTAL_KEYMODE_EXCLUSIVE;

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

        if (anchorButton != null)
        {
            var (x, y) = WidgetGeometryHelper.GetWidgetGlobalPos(anchorButton);
            var (screenWidth, screenHeight) = WidgetGeometryHelper.GetScreenSize();

            container.Measure(Orientation.Horizontal, -1, out _, out var natWidth, out _, out _);
            container.Measure(Orientation.Vertical, -1, out _, out var natHeight, out _, out _);

            int popupWidth = Math.Max(300, natWidth);
            int popupHeight = Math.Max(300, natHeight);

            _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT;

            int targetX = x + (anchorButton.GetAllocatedWidth() / 2) - (popupWidth / 2);
            int targetY = y + anchorButton.GetAllocatedHeight() + 4; // Tiny gap

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

        _backdrop = BackdropHelper.CreateBackdrop(_app, "calendar-popup-backdrop", AstalLayer.ASTAL_LAYER_OVERLAY, Hide);

        _window.GtkWindow.SetChild(container);
        _window.GtkWindow.Present();
        IsVisible = true;
    }

    public void Hide()
    {
        if (!IsVisible || _window == null) return;
        
        if (_backdrop != null)
        {
            _backdrop.GtkWindow.Close();
            _backdrop = null;
        }

        _window.GtkWindow.Close();
        _window = null;
        IsVisible = false;
    }
}
