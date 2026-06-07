using System;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Focus;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Phase E of the <c>river-layer-shell-v1</c> migration: tears down the per-seat
/// (<c>river_layer_shell_seat_v1</c>) and per-output (<c>river_layer_shell_output_v1</c>) sub-objects
/// when their parent <c>river_seat_v1</c>/<c>river_output_v1</c> is removed.
/// <para>
/// The XML makes the sub-objects inert once their parent is removed and requires the client to
/// destroy them. This service marshals the <c>destroy</c> request (opcode 0, with
/// <see cref="WaylandInterop.WL_MARSHAL_FLAG_DESTROY"/> which also frees the local proxy), drops the
/// association maps on <see cref="WaylandBindSiteState"/>, and clears the dependent focus/usable-area
/// state so a stale exclusive lock or usable-area hint can never outlive the parent.
/// </para>
/// <para>
/// Pump-thread only.
/// </para>
/// </summary>
internal sealed unsafe class LayerShellTeardownService : ILayerShellTeardownService
{
    private readonly WaylandBindSiteState _bindSiteState;
    private readonly ILayerShellFocusState _focusState;
    private readonly ILayerShellUsableAreaStore _usableAreas;

    public LayerShellTeardownService(
        WaylandBindSiteState bindSiteState,
        ILayerShellFocusState focusState,
        ILayerShellUsableAreaStore usableAreas)
    {
        _bindSiteState = bindSiteState ?? throw new ArgumentNullException(nameof(bindSiteState));
        _focusState = focusState ?? throw new ArgumentNullException(nameof(focusState));
        _usableAreas = usableAreas ?? throw new ArgumentNullException(nameof(usableAreas));
    }

    public void TeardownSeat(IntPtr seat)
    {
        if (seat == IntPtr.Zero)
        {
            return;
        }

        // Clear focus state first so a stale Exclusive lock can never permanently suppress focus,
        // even if the sub-object was never created (e.g. layer-shell global absent).
        _focusState.Clear(seat);

        if (!_bindSiteState.LayerShellSeatBySeat.TryRemove(seat, out var lsSeat) || lsSeat == IntPtr.Zero)
        {
            return;
        }

        _bindSiteState.SeatByLayerShellSeat.TryRemove(lsSeat, out _);
        DestroySubObject(lsSeat, RiverProtocolOpcodes.LayerShellSeat.Destroy, "layer_shell_seat");
    }

    public void TeardownOutput(IntPtr output)
    {
        if (output == IntPtr.Zero)
        {
            return;
        }

        // Drop the usable-area hint regardless of whether a sub-object exists.
        _usableAreas.Remove(output);

        if (!_bindSiteState.LayerShellOutputByOutput.TryRemove(output, out var lsOutput) || lsOutput == IntPtr.Zero)
        {
            return;
        }

        _bindSiteState.OutputByLayerShellOutput.TryRemove(lsOutput, out _);
        DestroySubObject(lsOutput, RiverProtocolOpcodes.LayerShellOutput.Destroy, "layer_shell_output");
    }

    private void DestroySubObject(IntPtr proxy, uint destroyOpcode, string label)
    {
        // Guard against double-destroy: only act if we were still tracking the proxy. Untrack first so
        // a re-entrant dispatch can't see it as live.
        if (!_bindSiteState.ProxyInterface.Untrack(proxy))
        {
            return;
        }

        // destroy is opcode 0 and a destructor on both sub-interfaces; marshal it with
        // WL_MARSHAL_FLAG_DESTROY which also frees the local proxy.
        WaylandInterop.wl_proxy_marshal_flags(
            proxy, destroyOpcode, IntPtr.Zero, 0, WaylandInterop.WL_MARSHAL_FLAG_DESTROY,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        RiverLog.Write($"- {label} 0x{proxy:x} (parent removed)");
    }
}
