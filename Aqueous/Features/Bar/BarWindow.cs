using System;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Gtk;

namespace Aqueous.Features.Bar
{
    public class BarWindow
    {
        private const int BarHeight = 32;
        private const int HitboxHeight = 2;

        private readonly AstalApplication _app;
        private AstalWindow? _bar;
        private uint _hideTimeout;
        private bool _barVisible;

        public AstalBox LeftSection { get; private set; } = null!;
        public AstalBox CenterSection { get; private set; } = null!;
        public AstalBox RightSection { get; private set; } = null!;

        public BarWindow(AstalApplication app)
        {
            _app = app;
            CreateBar();
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

            _bar.GtkWindow.SetDecorated(false);
            _bar.GtkWindow.SetDefaultSize(-1, 32);
            _bar.GtkWindow.AddCssClass("bar-window");

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
                ShowBar();
            };
            motionController.OnLeave += (_, _) =>
            {
                ScheduleHide();
            };
            _bar.GtkWindow.AddController(motionController);
        }

        public void Show()
        {
            _bar?.GtkWindow.Present();
            ShowBar();
            ScheduleHide();
        }

        public void ShowBar()
        {
            CancelHideTimeout();
            if (_bar != null && !_barVisible)
            {
                _barVisible = true;
                _bar.GtkWindow.SetDefaultSize(-1, BarHeight);
                _bar.GtkWindow.GetChild()?.SetVisible(true);
                _bar.GtkWindow.SetOpacity(1.0);
            }
        }

        public void HideBar()
        {
            CancelHideTimeout();
            if (_bar != null)
            {
                _bar.GtkWindow.GetChild()?.SetVisible(false);
                _bar.GtkWindow.SetDefaultSize(-1, HitboxHeight);
                _bar.GtkWindow.SetOpacity(0.01);
            }
            _barVisible = false;
        }

        private void ScheduleHide()
        {
            CancelHideTimeout();
            _hideTimeout = GLib.Functions.TimeoutAdd(0, 500, () =>
            {
                HideBar();
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

        public void Destroy()
        {
            CancelHideTimeout();
            _bar?.GtkWindow.Close();
            _bar = null;
        }
    }
}
