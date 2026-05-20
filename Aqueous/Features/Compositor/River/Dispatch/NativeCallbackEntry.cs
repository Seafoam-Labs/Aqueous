using System;
using Aqueous.Diagnostics;
using System.Runtime.InteropServices;

namespace Aqueous.Features.Compositor.River.Dispatch;

/// <summary>
/// The <see cref="UnmanagedCallersOnlyAttribute"/> entry function called by libwayland for every
/// event dispatched to a proxy whose dispatcher we own. lifted here so the god class no longer
/// owns the native callback.
/// <para>
/// Behaviour is byte-for-byte equivalent to the prior partial: the GCHandle anchor (<see
/// cref="RiverWindowManagerClient._selfHandle"/>) is unchanged for now — keeps the existing anchor
/// object so the lift is purely a relocation. A future PR (9.12 / cross-cutting concerns:
/// "GCHandle / native callback lifetime") may re-pin the handle to a dedicated
/// <c>NativeCallbackContext</c> owned by <c>RiverCompositorHost</c>.
/// </para>
/// <para>
/// Routing: interface-name lookup against the Stage-0 proxy → interface map, then dispatch via
/// <see cref="IEventDispatcher"/>. Screencopy frame proxies (owned by <c>WlrScreencopyClient</c>,
/// not tracked in the map) keep their dedicated fallback through
/// <c>IScreencopyService.TryDispatchFrameEvent</c>.
/// </para>
/// </summary>
internal static unsafe class NativeCallbackEntry
{
    [UnmanagedCallersOnly]
    internal static int Dispatch(IntPtr implementation, IntPtr target, uint opcode, IntPtr msg, IntPtr args)
    {
        try
        {
            var gch = GCHandle.FromIntPtr(implementation);
            // Route through RiverEventDispatcher rehydrated from the NativeCallbackContext pinned on the
            // GCHandle. The class fallback arm was retired alongside RiverWindowManagerClient itself.
            if (gch.Target is not NativeCallbackContext ctx)
            {
                return 0;
            }

            return ctx.Dispatcher.DispatchNative(target, opcode, args);
        }
        catch (Exception e)
        {
            // NEVER unwind into native dispatch.
            try
            {
                RiverLog.Write("dispatch exception: " + e.Message);
            }
            catch
            {
            }
        }

        return 0;
    }
}
