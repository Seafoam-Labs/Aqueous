using System;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;

namespace Aqueous.Helpers;

public static class BackdropHelper
{
    /// <summary>
    /// Tracks the number of live layer-shell surfaces we've created (backdrops + popup windows
    /// teared down through <see cref="DestroyWindow"/>). Used by the <c>AQUEOUS_DEBUG_SURFACES=1</c>
    /// diagnostic + shutdown assertion to detect leaked surfaces that would hold a keyboard grab
    /// or a live input region over other apps.
    /// </summary>
    public static int LiveSurfaceCount { get; private set; }

    /// <summary>
    /// Safety cap: if we ever observe more than this many simultaneous layer surfaces we refuse
    /// further creates. This is a fail-safe against a create/destroy churn bug that would
    /// otherwise overflow the libwayland 4 KB send buffer and crash the compositor link.
    /// </summary>
    private const int MaxLiveSurfaces = 8;

    private static readonly bool DebugSurfaces =
        Environment.GetEnvironmentVariable("AQUEOUS_DEBUG_SURFACES") == "1"
        || Environment.GetEnvironmentVariable("AQUEOUS_DEBUG_WAYLAND") == "1";

    static BackdropHelper()
    {
        if (Environment.GetEnvironmentVariable("AQUEOUS_DEBUG_WAYLAND") == "1"
            && string.IsNullOrEmpty(Environment.GetEnvironmentVariable("WAYLAND_DEBUG")))
        {
            // Surface libwayland protocol trace for the current process.
            Environment.SetEnvironmentVariable("WAYLAND_DEBUG", "1");
        }
    }

    /// <summary>
    /// Call from each popup immediately after setting <c>Keymode</c> on a layer surface so the
    /// diagnostic log tells us which popup owns which keymode. A no-op unless
    /// <c>AQUEOUS_DEBUG_SURFACES=1</c>.
    /// </summary>
    public static void LogLayerCreated(string ns, AstalKeymode keymode)
    {
        LiveSurfaceCount++;
        if (DebugSurfaces)
            Console.Error.WriteLine(
                $"[aqueous-surfaces] create ns={ns} keymode={keymode} live={LiveSurfaceCount}");
    }

    public static AstalWindow? CreateBackdrop(
        AstalApplication app,
        string ns,
        AstalLayer layer,
        Action onClicked)
    {
        // Leak cap: refuse to create a new layer surface if we already have too many live ones.
        // Logged so a regression is visible in stderr instead of silently overflowing the
        // Wayland send buffer and taking down the client.
        if (LiveSurfaceCount >= MaxLiveSurfaces)
        {
            Console.Error.WriteLine(
                $"[aqueous-surfaces] refusing CreateBackdrop ns={ns}: live={LiveSurfaceCount} exceeds cap {MaxLiveSurfaces}");
            return null;
        }

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
        // Opacity 0.0 (fully transparent) lets the compositor direct-scanout the toplevel
        // below; a non-zero alpha forces a full-screen composite per frame. The backdrop still
        // receives clicks because its input region covers the full surface.
        backdrop.GtkWindow.Opacity = 0.0;

        var click = Gtk.GestureClick.New();
        click.OnPressed += (_, _) => onClicked();
        backdrop.GtkWindow.AddController(click);

        // One configure pass: set all properties above first, then a single map+present.
        // Splitting visibility + present across main-loop ticks would produce an extra
        // layer-surface configure/ack round-trip per popup open.
        backdrop.GtkWindow.SetVisible(true);
        backdrop.GtkWindow.Present();

        LogLayerCreated(ns, AstalKeymode.ASTAL_KEYMODE_NONE);
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
    ///
    /// The actual unrealize/destroy is deferred one main-loop iteration so the preceding
    /// <c>SetVisible(false)</c> is flushed to the compositor first. Landing a <c>wl_surface.destroy</c>
    /// in the same batch as prior pending commits is the classic path to the libwayland
    /// "Data too big for buffer" overflow and subsequent crash.
    /// </summary>
    public static void DestroyWindow(ref AstalWindow? window)
    {
        if (window == null) return;
        var captured = window;
        window = null;

        string? ns = null;
        try { ns = captured.Namespace; } catch { }

        // Synchronous unmap — safe, ~1 request — schedule the hard teardown for the next
        // main-loop tick so the unmap has already been flushed.
        try { captured.GtkWindow.SetVisible(false); } catch { }

        GLib.Functions.IdleAdd(0, () =>
        {
            try
            {
                captured.GtkWindow.Unrealize();
                captured.GtkWindow.Destroy();
            }
            catch
            {
                // best-effort teardown; never throw during dismiss paths
            }
            finally
            {
                if (LiveSurfaceCount > 0) LiveSurfaceCount--;
                if (DebugSurfaces)
                    Console.Error.WriteLine(
                        $"[aqueous-surfaces] destroy ns={ns ?? "?"} live={LiveSurfaceCount}");
            }
            return false; // one-shot
        });
    }
}
