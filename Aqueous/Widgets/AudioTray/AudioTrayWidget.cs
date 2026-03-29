using System;
using System.Linq;
using Aqueous.Features.AudioSwitcher;
using Gtk;

namespace Aqueous.Widgets.AudioTray;

public class AudioTrayWidget
{
    private readonly Gtk.Button _button;

    public Gtk.Button Button => _button;

    public AudioTrayWidget(AudioSwitcherService service)
    {
        _button = Gtk.Button.New();
        _button.AddCssClass("audio-tray-button");

        var label = Gtk.Label.New("VOL");
        _button.SetChild(label);

        _button.OnClicked += (_, _) => service.Toggle();

        RefreshLabel(label);
        GLib.Functions.TimeoutAdd(0, 5000, () => { RefreshLabel(label); return true; });
    }

    private async void RefreshLabel(Gtk.Label label)
    {
        try
        {
            var sinks = await AudioBackend.ListSinks();
            var defaultSink = sinks.FirstOrDefault(s => s.IsDefault);
            var text = defaultSink != null
                ? Truncate(defaultSink.Description, 20)
                : "Audio";
            GLib.Functions.IdleAdd(0, () => { label.SetText(text); return false; });
        }
        catch { }
    }

    private static string Truncate(string s, int max) =>
        s.Length <= max ? s : s[..(max - 1)] + "...";
}
