using System;

namespace Aqueous.Helpers;

/// <summary>
/// Thin <see cref="IDisposable"/> wrapper around <see cref="GLib.Functions.TimeoutAdd"/> that
/// stores the returned source id so it can be cancelled — preventing the "timer leaks on panel
/// rebuild" pattern where <c>TimeoutAdd</c> is called but the returned id is discarded, leaving
/// the callback live forever and stacking duplicates across monitor hotplug / settings reload.
///
/// Usage:
/// <code>
///     _tick = ManagedTimer.Every(TimeSpan.FromSeconds(1), OnTick);
///     ...
///     _tick?.Dispose(); // cancels and frees
/// </code>
/// </summary>
public sealed class ManagedTimer : IDisposable
{
    private uint _sourceId;
    private readonly Func<bool> _callback;

    private ManagedTimer(uint intervalMs, Func<bool> callback)
    {
        _callback = callback;
        _sourceId = GLib.Functions.TimeoutAdd(0, intervalMs, Tick);
        LiveCount++;
    }

    /// <summary>Tracks live timers for debug leak detection (see AQUEOUS_PERF docs).</summary>
    public static int LiveCount { get; private set; }

    public static ManagedTimer Every(TimeSpan interval, Func<bool> callback) =>
        new((uint)interval.TotalMilliseconds, callback);

    public static ManagedTimer Every(uint intervalMs, Func<bool> callback) =>
        new(intervalMs, callback);

    /// <summary>Schedules a one-shot callback. The returned timer self-disposes after firing.</summary>
    public static ManagedTimer Once(TimeSpan delay, Action callback)
    {
        ManagedTimer? t = null;
        t = new ManagedTimer((uint)delay.TotalMilliseconds, () =>
        {
            try { callback(); } catch { }
            t?.Dispose();
            return false;
        });
        return t;
    }

    private bool Tick()
    {
        bool keep;
        try { keep = _callback(); }
        catch { keep = false; }

        if (!keep)
        {
            // GLib already removed the source since we returned false; just clear our id.
            if (_sourceId != 0)
            {
                _sourceId = 0;
                LiveCount--;
            }
        }
        return keep;
    }

    public void Dispose()
    {
        if (_sourceId == 0) return;
        try { GLib.Functions.SourceRemove(_sourceId); }
        catch { }
        _sourceId = 0;
        LiveCount--;
    }
}
