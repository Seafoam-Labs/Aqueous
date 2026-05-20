using System;
using System.Runtime.InteropServices;
namespace Aqueous.Features.Compositor.River.Dispatch;

/// <summary>
/// Stage 9 PR 9.12 §2.10 — native-callback lifetime holder. Owns the
/// <see cref="GCHandle"/> pinned across libwayland's
/// <c>wl_dispatcher_func_t</c> boundary plus a back-pointer to the
/// <see cref="RiverEventDispatcher"/> that <see cref="NativeCallbackEntry.Dispatch"/>
/// will route into once the GCHandle is re-pinned in §2.13.
///
/// <para>
/// This type is the structural seam: in §2.13 the god-class
/// <c>_selfHandle</c> is replaced with an instance of
/// <c>NativeCallbackContext</c> allocated and pinned by
/// <c>RiverCompositorHost.StartAsync</c>, then freed in
/// <c>StopAsync</c>. Today the type is constructed but not yet on the
/// dispatch path — wiring it in is the final §2.13 cutover.
/// </para>
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
