using System;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Gtk;

namespace Aqueous.Features.Bar
{
    public class BarWindow
    {
        private readonly AstalApplication _app;
        private AstalWindow? _trigger;
        private AstalWindow? _bar;
        private uint _hideTimeout;
        private bool _barVisible;

        public AstalBox LeftSection { get; private set; } = null!;
        public AstalBox CenterSection { get; private set; } = null!;
        public AstalBox RightSection { get; private set; } = null!;

        public BarWindow(AstalApplication app)
        {
            _app = app;
            CreateTrigger();
            CreateBar();
        }

        private void CreateTrigger()
        {
            _trigger = new AstalWindow();
            _app.GtkApplication.AddWindow(_trigger.GtkWindow);
            _trigger.Namespace = "bar-trigger";
            _trigger.Layer = AstalLayer.ASTAL_LAYER_TOP;
            _trigger.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_NORMAL;
            _trigger.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                            | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT
                            | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;

            _trigger.GtkWindow.SetDecorated(false); // Remove window frame/shadow
            _trigger.GtkWindow.SetCanFocus(false);   // Prevent it from taking keyboard focus
            _trigger.GtkWindow.SetDefaultSize(-1, 32);
            _trigger.GtkWindow.AddCssClass("bar-trigger");

            var triggerBox = new AstalBox();
            triggerBox.GtkBox.SetSizeRequest(-1, 32);
            _trigger.GtkWindow.SetChild(triggerBox.GtkBox);

            var motionController = Gtk.EventControllerMotion.New();
            motionController.OnEnter += (_, _) =>
            {
                ShowBar();
            };
            _trigger.GtkWindow.AddController(motionController);
        }

        private void CreateBar()
        {
            _bar = new AstalWindow();
            _app.GtkApplication.AddWindow(_bar.GtkWindow);
            _bar.Namespace = "bar-window";
            _bar.Layer = AstalLayer.ASTAL_LAYER_TOP;
            _bar.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_NORMAL;
            _bar.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                        | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT
                        | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;

            _bar.GtkWindow.SetDecorated(false); // Remove window frame/shadow
            _bar.GtkWindow.SetDefaultSize(-1, 32);
            _bar.GtkWindow.AddCssClass("bar-window");
            _bar.GtkWindow.SetVisible(false);

            // Main layout container
            var layout = new AstalBox();
            layout.Vertical = false;
            layout.GtkBox.Hexpand = true;
            layout.GtkBox.AddCssClass("bar-layout");
            _bar.GtkWindow.SetChild(layout.GtkBox);

            // Single centered bar box
            var barBox = new AstalBox();
            barBox.Vertical = false;
            barBox.GtkBox.Hexpand = false;
            barBox.GtkBox.Halign = Align.Center;
            barBox.GtkBox.AddCssClass("bar-section");
            
            // Left spacer
            var leftSpacer = new AstalBox();
            leftSpacer.GtkBox.Hexpand = true;
            leftSpacer.GtkBox.AddCssClass("bar-side");
            leftSpacer.GtkBox.Opacity = 0;
            layout.GtkBox.Append(leftSpacer.GtkBox);

            layout.GtkBox.Append(barBox.GtkBox);

            // Right spacer
            var rightSpacer = new AstalBox();
            rightSpacer.GtkBox.Hexpand = true;
            rightSpacer.GtkBox.AddCssClass("bar-side");
            rightSpacer.GtkBox.Opacity = 0;
            layout.GtkBox.Append(rightSpacer.GtkBox);

            // Left content area (inside the single box)
            LeftSection = new AstalBox();
            LeftSection.Vertical = false;
            LeftSection.GtkBox.Hexpand = true;
            LeftSection.GtkBox.Halign = Align.Start;
            barBox.GtkBox.Append(LeftSection.GtkBox);

            // Center content area
            CenterSection = new AstalBox();
            CenterSection.Vertical = false;
            CenterSection.GtkBox.Hexpand = true;
            CenterSection.GtkBox.Halign = Align.Center;
            barBox.GtkBox.Append(CenterSection.GtkBox);

            // Right content area
            RightSection = new AstalBox();
            RightSection.Vertical = false;
            RightSection.GtkBox.Hexpand = true;
            RightSection.GtkBox.Halign = Align.End;
            barBox.GtkBox.Append(RightSection.GtkBox);

            var motionController = Gtk.EventControllerMotion.New();
            motionController.OnEnter += (_, _) =>
            {
                CancelHideTimeout();
            };
            motionController.OnLeave += (_, _) =>
            {
                ScheduleHide();
            };
            _bar.GtkWindow.AddController(motionController);
        }

        public void Show()
        {
            // Ensure the trigger window is active and capturing events
            _trigger?.GtkWindow.Present();

            // Briefly show the bar on startup for user feedback, then hide it
            ShowBar();
            ScheduleHide();
        }

        public void ShowBar()
        {
            CancelHideTimeout();
            if (_bar != null && !_barVisible)
            {
                _bar.GtkWindow.SetVisible(true);
                _bar.GtkWindow.Present();
                _barVisible = true;
            }
        }

        public void HideBar()
        {
            CancelHideTimeout();
            if (_bar != null)
            {
                _bar.GtkWindow.SetVisible(false);
            }
            _barVisible = false;
        }

        private void ScheduleHide()
        {
            CancelHideTimeout();
            _hideTimeout = GLib.Functions.TimeoutAdd(0, 500, () =>
            {
                HideBar();
                _hideTimeout = 0; // Reset after execution
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

        public void Destroy()
        {
            CancelHideTimeout();
            _trigger?.GtkWindow.Close();
            _bar?.GtkWindow.Close();
            _trigger = null;
            _bar = null;
        }
    }
}
