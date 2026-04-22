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
        DestroyWindow(ref backdrop);
    }

    /// <summary>
    /// Hard teardown for any layer-shell <see cref="AstalWindow"/>: unmap + unrealize + destroy so
    /// the underlying wl_surface / zwlr_layer_surface is released immediately, instead of lingering
    /// for a frame and eating clicks on apps above/below. Use this on every popup dismiss path
    /// instead of <c>GtkWindow.Close()</c> or <c>SetVisible(false)</c>.
    /// </summary>
    public static void DestroyWindow(ref AstalWindow? window)
    {
        if (window == null) return;
        try
        {
            window.GtkWindow.SetVisible(false);
            window.GtkWindow.Unrealize();
            window.GtkWindow.Destroy();
        }
        catch
        {
            // best-effort teardown; never throw during dismiss paths
        }
        window = null;
    }
}
