using System;
using System.Threading;

namespace Aqueous.Features.Focus;

/// <summary>
/// Singleton holding the raw <see cref="IntPtr"/> handle of the currently-focused River window
/// (river_window_v1 proxy pointer). Introduced to peel focus-pointer ownership away from
/// <c>RiverWindowManagerClient._focusedWindow</c>.
/// <para>
/// During the incremental lift the god class's <c>_focusedWindow</c> field is rewritten as a
/// property that reads/writes <see cref="Current"/>. Once every consumer takes the tracker via
/// ctor injection, the property is removed entirely.
/// </para>
/// <para>
/// Backed by an <see cref="IntPtr"/> volatile read/write so seat-handler and pump-thread observers
/// always see a torn-free pointer; no other thread-safety guarantees are made (writes are confined
/// to the dispatch / connect threads, same as the original field).
/// </para>
/// </summary>
internal sealed class FocusedWindowTracker
{
    private IntPtr _current;
    private long _tick;

    public IntPtr Current
    {
        get => Volatile.Read(ref _current);
        set
        {
            var old = Volatile.Read(ref _current);
            Volatile.Write(ref _current, value);
            // Bump the monotonic focus tick whenever the focused window actually changes.
            // PR #4 step 2: GameModeLayout uses this tick to pick the most-recently-focused
            // anchor candidate when multiple matching windows share an output. The bump on
            // every transition (including to/from IntPtr.Zero) is acceptable — only the
            // relative ordering of ticks across windows matters.
            if (value != IntPtr.Zero && value != old)
            {
                Interlocked.Increment(ref _tick);
            }
        }
    }

    /// <summary>
    /// Monotonically-increasing counter incremented on every focus transition to a real
    /// window. Read by callers (e.g. <c>LayoutProposer</c>) that need to stamp the
    /// currently-focused <c>WindowEntry.LastFocusTick</c>.
    /// </summary>
    public long CurrentTick => Volatile.Read(ref _tick);
}
