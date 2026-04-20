using System;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Gtk;

namespace Aqueous.Helpers
{
    public static class WidgetGeometryHelper
    {
        public static unsafe (int width, int height) GetScreenSize()
        {
            return GetScreenSize(0);
        }

        public static unsafe (int width, int height) GetScreenSize(int monitorIdx)
        {
            try
            {
                var display = GdkInterop.gdk_display_get_default();
                if (display != null)
                {
                    var monitors = GdkInterop.gdk_display_get_monitors(display);
                    if (monitors != null && GdkInterop.g_list_model_get_n_items(monitors) > monitorIdx)
                    {
                        var monitor = (_GdkMonitor*)GdkInterop.g_list_model_get_item(monitors, (uint)monitorIdx);
                        if (monitor != null)
                        {
                            GdkInterop.gdk_monitor_get_geometry(monitor, out var geo);
                            return (geo.Width, geo.Height);
                        }
                    }
                }
            }
            catch
            {
            }
            return (1920, 1080);
        }

        public static unsafe (int x, int y) GetWidgetGlobalPos(Widget widget)
        {
            double x = 0, y = 0;
            var native = widget.GetNative();
            if (native == null) return ((int)x, (int)y);
            
            widget.TranslateCoordinates((Widget)native, 0, 0, out x, out y);
            
            var win = (Gtk.Window)native;
            var handle = (_AstalWindow*)win.Handle.DangerousGetHandle();

            var anchor = AstalGtk4Interop.astal_window_get_anchor(handle);
            var monitorIdx = AstalGtk4Interop.astal_window_get_monitor(handle);
            var marginLeft = AstalGtk4Interop.astal_window_get_margin_left(handle);
            var marginTop = AstalGtk4Interop.astal_window_get_margin_top(handle);
            var marginRight = AstalGtk4Interop.astal_window_get_margin_right(handle);
            var marginBottom = AstalGtk4Interop.astal_window_get_margin_bottom(handle);

            var (screenWidth, screenHeight) = GetScreenSize(monitorIdx);

            // Horizontal translation
            if ((anchor & AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT) != 0 && (anchor & AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT) != 0)
            {
                // Centered (like the bar)
                var barWidth = win.GetAllocatedWidth();
                x += marginLeft + (screenWidth - barWidth - marginLeft - marginRight) / 2;
            }
            else if ((anchor & AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT) != 0)
            {
                x = screenWidth - marginRight - (win.GetAllocatedWidth() - x);
            }
            else
            {
                x += marginLeft;
            }

            // Vertical translation
            if ((anchor & AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP) != 0 && (anchor & AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_BOTTOM) != 0)
            {
                // Centered vertically
                var barHeight = win.GetAllocatedHeight();
                y += marginTop + (screenHeight - barHeight - marginTop - marginBottom) / 2;
            }
            else if ((anchor & AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_BOTTOM) != 0)
            {
                y = screenHeight - marginBottom - (win.GetAllocatedHeight() - y);
            }
            else
            {
                y += marginTop;
            }

            return ((int)x, (int)y);
        }
    }
}
