using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Gtk;

namespace Aqueous.Features.Dock
{
    public partial class DockWindow
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct GdkRectangle { public int X, Y, Width, Height; }

        [LibraryImport("libgdk-4.so.1")]
        private static partial IntPtr gdk_display_get_default();

        [LibraryImport("libgdk-4.so.1")]
        private static partial IntPtr gdk_display_get_monitors(IntPtr display);

        [LibraryImport("libgio-2.0.so.0")]
        private static partial IntPtr g_list_model_get_item(IntPtr list, uint position);

        [LibraryImport("libgio-2.0.so.0")]
        private static partial uint g_list_model_get_n_items(IntPtr list);

        [LibraryImport("libgdk-4.so.1")]
        private static partial void gdk_monitor_get_geometry(IntPtr monitor, out GdkRectangle geometry);

        private readonly AstalApplication _app;
        private AstalWindow? _triggerStrip;
        private AstalWindow? _dockPanel;
        private AstalBox? _dockBox;
        private DockPosition _position;
        private uint _hideTimeout;
        private bool _dockVisible;
        private Gtk.CssProvider? _dynamicCssProvider;

        public DockWindow(AstalApplication app, DockPosition position)
        {
            _app = app;
            _position = position;
        }

        public void Show()
        {
            if (_position == DockPosition.Hidden) return;
            CreateTriggerStrip();
            CreateDockPanel();
            _triggerStrip?.GtkWindow.Present();

            // Present dock panel briefly on startup, then auto-hide
            _dockPanel?.GtkWindow.Present();
            _dockVisible = true;
            ScheduleHide();
        }

        public void Hide()
        {
            DestroyDockPanel();
            if (_triggerStrip != null)
            {
                _triggerStrip.GtkWindow.Close();
                _triggerStrip = null;
            }
        }

        public void Rebuild(DockPosition newPosition)
        {
            Hide();
            _position = newPosition;
            if (_position != DockPosition.Hidden)
                Show();
        }

        public void AddItem(Gtk.Widget widget)
        {
            _dockBox?.GtkBox.Append(widget);
            RecalculateIconSize();
        }

        public void RemoveItem(Gtk.Widget widget)
        {
            _dockBox?.GtkBox.Remove(widget);
            RecalculateIconSize();
        }

        public void SetItemRunning(Gtk.Widget widget, bool running)
        {
            if (running)
                widget.AddCssClass("dock-item-running");
            else
                widget.RemoveCssClass("dock-item-running");
        }

        private (int width, int height) GetScreenSize()
        {
            try
            {
                var display = gdk_display_get_default();
                if (display != IntPtr.Zero)
                {
                    var monitors = gdk_display_get_monitors(display);
                    if (monitors != IntPtr.Zero && g_list_model_get_n_items(monitors) > 0)
                    {
                        var monitor = g_list_model_get_item(monitors, 0);
                        if (monitor != IntPtr.Zero)
                        {
                            gdk_monitor_get_geometry(monitor, out var geo);
                            return (geo.Width, geo.Height);
                        }
                    }
                }
            }
            catch
            {
                // Fallback on any GDK error
            }
            return (1920, 1080);
        }

        /// <summary>
        /// Positions the dock in the middle third using a single margin (top or left)
        /// with two-edge anchoring. This avoids the three-edge + dual-margin pattern
        /// that caused Wayfire to compute negative surface dimensions.
        /// </summary>
        private void ApplyMiddleThirdMargin(AstalWindow window)
        {
            var (screenWidth, screenHeight) = GetScreenSize();

            switch (_position)
            {
                case DockPosition.Left:
                case DockPosition.Right:
                    // Two-edge anchor (LEFT|TOP or RIGHT|TOP): offset down by 1/3 screen height
                    window.MarginTop = screenHeight / 3;
                    break;
                case DockPosition.Bottom:
                    // Two-edge anchor (BOTTOM|LEFT): offset right by 1/3 screen width
                    window.MarginLeft = screenWidth / 3;
                    break;
            }
        }

        private AstalWindowAnchor GetAnchors()
        {
            return _position switch
            {
                DockPosition.Left => AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT
                                   | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP,
                DockPosition.Bottom => AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_BOTTOM
                                     | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT,
                DockPosition.Right => AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT
                                    | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP,
                _ => AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT
                   | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP,
            };
        }

        private void CreateTriggerStrip()
        {
            _triggerStrip = new AstalWindow();
            _app.GtkApplication.AddWindow(_triggerStrip.GtkWindow);
            _triggerStrip.Namespace = "dock-trigger";
            _triggerStrip.Layer = AstalLayer.ASTAL_LAYER_TOP;
            _triggerStrip.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_NORMAL;
            _triggerStrip.Anchor = GetAnchors();

            var isVertical = _position == DockPosition.Left || _position == DockPosition.Right;
            if (isVertical)
                _triggerStrip.GtkWindow.SetDefaultSize(4, 50);
            else
                _triggerStrip.GtkWindow.SetDefaultSize(50, 4);

            _triggerStrip.GtkWindow.AddCssClass("dock-trigger");

            // Add a child widget so the trigger strip has content to size to
            var triggerBox = Gtk.Box.New(Gtk.Orientation.Vertical, 0);
            var isVerticalTrigger = _position == DockPosition.Left || _position == DockPosition.Right;
            if (isVerticalTrigger)
                triggerBox.SetSizeRequest(4, 50);
            else
                triggerBox.SetSizeRequest(50, 4);
            _triggerStrip.GtkWindow.SetChild(triggerBox);

            ApplyMiddleThirdMargin(_triggerStrip);

            var motionController = Gtk.EventControllerMotion.New();
            motionController.OnEnter += (_, _) =>
            {
                ShowDockPanel();
            };
            _triggerStrip.GtkWindow.AddController(motionController);
        }

        private void CreateDockPanel()
        {
            _dockPanel = new AstalWindow();
            _app.GtkApplication.AddWindow(_dockPanel.GtkWindow);
            _dockPanel.Namespace = "dock-panel";
            _dockPanel.Layer = AstalLayer.ASTAL_LAYER_TOP;
            _dockPanel.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_NORMAL;
            _dockPanel.Anchor = GetAnchors();

            _dockPanel.GtkWindow.AddCssClass("dock-panel");

            var isVertical = _position == DockPosition.Left || _position == DockPosition.Right;
            if (isVertical)
                _dockPanel.GtkWindow.SetDefaultSize(40, 50);
            else
                _dockPanel.GtkWindow.SetDefaultSize(50, 40);
            _dockBox = new AstalBox();
            _dockBox.Vertical = isVertical;
            _dockBox.GtkBox.AddCssClass("dock-container");

            _dockPanel.GtkWindow.SetChild(_dockBox.GtkBox);

            ApplyMiddleThirdMargin(_dockPanel);

            var motionController = Gtk.EventControllerMotion.New();
            motionController.OnEnter += (_, _) =>
            {
                CancelHideTimeout();
            };
            motionController.OnLeave += (_, _) =>
            {
                ScheduleHide();
            };
            _dockPanel.GtkWindow.AddController(motionController);
        }

        private void ShowDockPanel()
        {
            CancelHideTimeout();
            if (_dockPanel != null && !_dockVisible)
            {
                _dockPanel.GtkWindow.SetVisible(true);
                _dockPanel.GtkWindow.Present();
                _dockVisible = true;
            }
        }

        /// <summary>
        /// Auto-hide: preserves the window and its children, just hides it.
        /// </summary>
        private void HideDockPanel()
        {
            CancelHideTimeout();
            if (_dockPanel != null)
            {
                _dockPanel.GtkWindow.SetVisible(false);
            }
            _dockVisible = false;
        }

        /// <summary>
        /// Full teardown: destroys the dock panel window and all children.
        /// Used by Hide() during Rebuild/Stop.
        /// </summary>
        private void DestroyDockPanel()
        {
            CancelHideTimeout();
            if (_dockPanel != null)
            {
                _dockPanel.GtkWindow.Close();
                _dockPanel = null;
                _dockBox = null;
            }
            _dockVisible = false;
        }

        private void ScheduleHide()
        {
            CancelHideTimeout();
            _hideTimeout = GLib.Functions.TimeoutAdd(0, 300, () =>
            {
                HideDockPanel();
                _hideTimeout = 0;
                return false;
            });
        }

        private void CancelHideTimeout()
        {
            if (_hideTimeout != 0)
            {
                GLib.Functions.SourceRemove(_hideTimeout);
                _hideTimeout = 0;
            }
        }

        private void RecalculateIconSize()
        {
            if (_dockBox == null || _dockPanel == null) return;

            // Count children
            int itemCount = 0;
            var child = _dockBox.GtkBox.GetFirstChild();
            while (child != null)
            {
                itemCount++;
                child = child.GetNextSibling();
            }
            if (itemCount == 0) return;

            var (screenWidth, screenHeight) = GetScreenSize();
            bool isVertical = _position == DockPosition.Left || _position == DockPosition.Right;
            int availableSpace = isVertical ? screenHeight / 3 : screenWidth / 3;

            int padding = 8; // per item (top+bottom or left+right padding)
            int maxIconSize = 40;
            int minIconSize = 16;
            int iconSize = Math.Clamp((availableSpace / itemCount) - padding, minIconSize, maxIconSize);

            // Apply via dynamic CSS
            if (_dynamicCssProvider == null)
            {
                _dynamicCssProvider = Gtk.CssProvider.New();
                Gtk.StyleContext.AddProviderForDisplay(
                    Gdk.Display.GetDefault()!,
                    _dynamicCssProvider,
                    Gtk.Constants.STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
            }

            _dynamicCssProvider.LoadFromString(
                $".dock-item {{ min-width: {iconSize}px; min-height: {iconSize}px; padding: {Math.Max(2, iconSize / 8)}px; }}" +
                $".dock-item-icon {{ -gtk-icon-size: {iconSize}px; }}");
        }
    }
}
