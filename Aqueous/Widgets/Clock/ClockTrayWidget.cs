namespace Aqueous.Widgets.Clock;

public class ClockTrayWidget
{
    private readonly Gtk.Label _label;

    public Gtk.Label Label => _label;
    private readonly bool _is24Hour = false;
    private bool _isRunning = false;

    public ClockTrayWidget(bool is24Hour = false)
    {
        _is24Hour = is24Hour;
        _label = Gtk.Label.New("Loading...");
        _label.AddCssClass("clock-label");
    }

    public void Start()
    {
        if (_isRunning)
        {
            return;
        }

        _isRunning = true;

        GLib.Functions.TimeoutAdd(200, 1000, () =>
        {
            UpdateClock();
            return true;
        });
    }

    private void UpdateClock()
    {
        var format = _is24Hour ? "HH:mm:ss" : "hh:mm:ss tt";
        var timeString = DateTime.Now.ToString($"{format} MM/dd/yyyy");

        GLib.Functions.IdleAdd(200, () =>
        {
            _label.SetText(timeString);
            return false;
        });
    }
}