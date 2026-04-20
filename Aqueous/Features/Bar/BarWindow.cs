using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Aqueous.Features.Settings;
using Aqueous.Helpers;
using Gtk;

namespace Aqueous.Features.Bar
{
    public partial class BarWindow
    {
        private const int BarHeight = 32;
        private const int HitboxHeight = 2;

        private readonly AstalApplication _app;
        private AstalWindow? _bar;
        private uint _hideTimeout;
        private bool _barVisible;
        private int _preventHideCount;

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
                        | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT;

            _bar.GtkWindow.SetDecorated(false);
            var (screenWidth, _) = WidgetGeometryHelper.GetScreenSize();
            var barWidth = screenWidth / 3;
            _bar.GtkWindow.SetDefaultSize(barWidth, BarHeight);
            _bar.GtkWindow.AddCssClass("bar-window");

            // Main layout container
            var layout = new AstalBox();
            layout.Vertical = false;
            layout.GtkBox.Hexpand = true;
            layout.GtkBox.AddCssClass("bar-layout");
            _bar.GtkWindow.SetChild(layout.GtkBox);
            ApplyMiddleThirdMargin();

            // Single centered bar box
            var barBox = new AstalBox();
            barBox.Vertical = false;
            barBox.GtkBox.Hexpand = false;
            barBox.GtkBox.Halign = Align.Center;
            barBox.GtkBox.AddCssClass("bar-section");

            barBox.GtkBox.Hexpand = true;
            layout.GtkBox.Append(barBox.GtkBox);

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
                var (sw, _) = WidgetGeometryHelper.GetScreenSize();
                _bar.GtkWindow.SetDefaultSize(sw / 3, BarHeight);
                _bar.GtkWindow.GetChild()?.SetVisible(true);
                _bar.GtkWindow.SetOpacity(SettingsStore.Instance.Data.PanelOpacity);
            }
        }

        public void HideBar()
        {
            CancelHideTimeout();
            if (_bar != null)
            {
                _bar.GtkWindow.GetChild()?.SetVisible(false);
                var (sw2, _) = WidgetGeometryHelper.GetScreenSize();
                _bar.GtkWindow.SetDefaultSize(sw2 / 3, HitboxHeight);
                _bar.GtkWindow.SetOpacity(0.01);
            }
            _barVisible = false;
        }

        public void PreventHide()
        {
            _preventHideCount++;
            CancelHideTimeout();
        }

        public void AllowHide()
        {
            _preventHideCount--;
            if (_preventHideCount <= 0)
            {
                _preventHideCount = 0;
                ScheduleHide();
            }
        }

        private void ScheduleHide()
        {
            if (_preventHideCount > 0) return;
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

        private void ApplyMiddleThirdMargin()
        {
            if (_bar == null) return;
            var (screenWidth, _) = WidgetGeometryHelper.GetScreenSize();
            var barWidth = screenWidth / 3;
            _bar.MarginLeft = (screenWidth - barWidth) / 2;
        }

        public void Destroy()
        {
            CancelHideTimeout();
            _bar?.GtkWindow.Close();
            _bar = null;
        }
    }
}
