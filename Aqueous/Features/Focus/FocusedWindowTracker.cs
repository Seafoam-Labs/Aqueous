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

    public IntPtr Current
    {
        get => Volatile.Read(ref _current);
        set => Volatile.Write(ref _current, value);
    }
}
