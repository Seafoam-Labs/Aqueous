using System;
using System.Runtime.InteropServices;
namespace Aqueous.Features.Compositor.River.Dispatch;

/// <summary>
/// PR 9.12 §2.13 Step 10 — native-callback lifetime holder. Owns the
/// <see cref="GCHandle"/> pinned across libwayland's
/// <c>wl_dispatcher_func_t</c> boundary plus a back-pointer to the
/// <see cref="RiverEventDispatcher"/> that
/// <see cref="NativeCallbackEntry.Dispatch"/> routes into. The legacy
/// god-class back-reference was removed in Step 10 once
/// <see cref="RiverEventDispatcher"/> stopped depending on
/// <c>RiverWindowManagerClient</c>.
/// </summary>
internal sealed class NativeCallbackContext : IDisposable
{
    internal RiverEventDispatcher Dispatcher { get; }

    private GCHandle _handle;
    private bool _disposed;

    internal NativeCallbackContext(RiverEventDispatcher dispatcher)
    {
        Dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        _handle = GCHandle.Alloc(this, GCHandleType.Normal);
    }

    /// <summary>
    /// The opaque <c>IntPtr</c> handed to libwayland as the dispatcher
    /// <c>implementation</c> pointer. Round-tripped back through
    /// <see cref="GCHandle.FromIntPtr"/> in
    /// <see cref="NativeCallbackEntry.Dispatch"/>.
    /// </summary>
    internal IntPtr Handle => GCHandle.ToIntPtr(_handle);

    internal bool IsAllocated => !_disposed && _handle.IsAllocated;

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        if (_handle.IsAllocated)
        {
            _handle.Free();
        }
    }
}
