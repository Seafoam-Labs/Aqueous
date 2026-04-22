using System;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using Aqueous.Features.AudioSwitcher;
using Gtk;

namespace Aqueous.Widgets.AudioTray;

/// <summary>
/// Audio tray button. Previously this widget spawned <c>pactl</c> every 5 s to refresh its
/// label (17,280 forks/day). It now listens to <c>pactl subscribe</c> — a single long-lived
/// process whose stdout only emits when sinks/servers actually change — and refreshes on
/// those events, plus once at construction.
/// </summary>
public sealed class AudioTrayWidget : IDisposable
{
    private readonly Gtk.Button _button;
    private readonly Gtk.Label _label;
    private Process? _subscribeProcess;

    public Gtk.Button Button => _button;

    public AudioTrayWidget(AudioSwitcherService service)
    {
        _button = Gtk.Button.New();
        _button.AddCssClass("audio-tray-button");

        _label = Gtk.Label.New("VOL");
        _button.SetChild(_label);

        _button.OnClicked += (_, _) => service.Toggle(_button);

        // Prime label once; subsequent refreshes are event-driven.
        RefreshLabel();
        StartPactlSubscription();
    }

    private void StartPactlSubscription()
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "pactl",
                Arguments = "subscribe",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            _subscribeProcess = Process.Start(psi);
            if (_subscribeProcess == null) return;

            _subscribeProcess.OutputDataReceived += (_, e) =>
            {
                if (string.IsNullOrEmpty(e.Data)) return;
                // Only refresh on sink/server change events — ignore high-rate events
                // like "client" or "sink-input" which fire on every app volume tick.
                if (e.Data.Contains("on sink ") || e.Data.Contains("on server "))
                    GLib.Functions.IdleAdd(0, () => { RefreshLabel(); return false; });
            };
            _subscribeProcess.BeginOutputReadLine();
        }
        catch
        {
            // pactl unavailable — leave the primed label as-is.
        }
    }

    private async void RefreshLabel()
    {
        try
        {
            var sinks = await AudioBackend.ListSinks();
            var defaultSink = sinks.FirstOrDefault(s => s.IsDefault);
            var text = defaultSink != null
                ? Truncate(defaultSink.Description, 20)
                : "Audio";
            GLib.Functions.IdleAdd(0, () => { _label.SetText(text); return false; });
        }
        catch { }
    }

    public void Dispose()
    {
        try
        {
            if (_subscribeProcess is { HasExited: false })
            {
                _subscribeProcess.Kill();
            }
            _subscribeProcess?.Dispose();
        }
        catch { }
        _subscribeProcess = null;
    }

    private static string Truncate(string s, int max) =>
        s.Length <= max ? s : s[..(max - 1)] + "...";
}
