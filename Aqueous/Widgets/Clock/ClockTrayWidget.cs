using System;

namespace Aqueous.Widgets.Clock;

public enum ClockResolution
{
    Minutes,
    Seconds
}

public class ClockTrayWidget : IDisposable
{
    private readonly Gtk.Label _label;
    private readonly Gtk.Button _button;

    public Gtk.Label Label => _label;
    public Gtk.Button Button => _button;
    private readonly bool _is24Hour;
    private readonly ClockResolution _resolution;
    private bool _isRunning;
    private uint _tickSource;

    public ClockTrayWidget(
        bool is24Hour = false,
        Action<Gtk.Button>? onClick = null,
        ClockResolution resolution = ClockResolution.Minutes)
    {
        _is24Hour = is24Hour;
        _resolution = resolution;
        _label = Gtk.Label.New("Loading...");
        _label.AddCssClass("clock-label");

        _button = Gtk.Button.New();
        _button.SetChild(_label);
        _button.AddCssClass("clock-button");

        if (onClick != null)
            _button.OnClicked += (_, _) => onClick(_button);
    }

    public void Start()
    {
        if (_isRunning) return;
        _isRunning = true;

        // Prime the label immediately.
        UpdateClock();

        // Align the first tick to the next second/minute boundary so the label flips at the
        // correct time and subsequent ticks don't drift against other periodic work.
        var now = DateTime.Now;
        uint firstDelay;
        uint periodMs;
        if (_resolution == ClockResolution.Seconds)
        {
            firstDelay = (uint)Math.Max(1, 1000 - now.Millisecond);
            periodMs = 1000;
        }
        else
        {
            firstDelay = (uint)Math.Max(1, (60 - now.Second) * 1000 - now.Millisecond);
            periodMs = 60_000;
        }

        _tickSource = GLib.Functions.TimeoutAdd(200, firstDelay, () =>
        {
            UpdateClock();
            // Switch to steady-state period after first aligned tick.
            if (_tickSource != 0)
                GLib.Functions.SourceRemove(_tickSource);
            _tickSource = GLib.Functions.TimeoutAdd(200, periodMs, () =>
            {
                UpdateClock();
                return true;
            });
            return false;
        });
    }

    public void Stop()
    {
        if (_tickSource != 0)
        {
            try { GLib.Functions.SourceRemove(_tickSource); } catch { }
            _tickSource = 0;
        }
        _isRunning = false;
    }

    public void Dispose() => Stop();

    private void UpdateClock()
    {
        string timeFormat = _resolution == ClockResolution.Seconds
            ? (_is24Hour ? "HH:mm:ss" : "hh:mm:ss tt")
            : (_is24Hour ? "HH:mm"    : "hh:mm tt");
        var timeString = DateTime.Now.ToString($"{timeFormat} MM/dd/yyyy");

        GLib.Functions.IdleAdd(200, () =>
        {
            _label.SetText(timeString);
            return false;
        });
    }
}
