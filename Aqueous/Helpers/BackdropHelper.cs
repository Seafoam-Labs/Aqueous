using System;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;

namespace Aqueous.Helpers;

public static class BackdropHelper
{
    public static AstalWindow CreateBackdrop(
        AstalApplication app,
        string ns,
        AstalLayer layer,
        Action onClicked)
    {
        var backdrop = new AstalWindow();
        app.GtkApplication.AddWindow(backdrop.GtkWindow);
        backdrop.Namespace = ns;
        backdrop.Layer = layer;
        backdrop.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_IGNORE;
        backdrop.Keymode = AstalKeymode.ASTAL_KEYMODE_NONE;
        backdrop.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                        | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_BOTTOM
                        | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT
                        | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;
        backdrop.GtkWindow.Opacity = 0.01;

        var click = Gtk.GestureClick.New();
        click.OnPressed += (_, _) => onClicked();
        backdrop.GtkWindow.AddController(click);

        backdrop.GtkWindow.SetVisible(true);
        backdrop.GtkWindow.Present();
        return backdrop;
    }

    public static void DestroyBackdrop(ref AstalWindow? backdrop)
    {
        if (backdrop == null) return;
        backdrop.GtkWindow.SetVisible(false);
        backdrop.GtkWindow.Close();
        backdrop = null;
    }
}
