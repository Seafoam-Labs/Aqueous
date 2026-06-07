using System;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Tears down the per-seat / per-output <c>river-layer-shell-v1</c> sub-objects when their parent
/// <c>river_seat_v1</c>/<c>river_output_v1</c> is removed. See <see cref="LayerShellTeardownService"/>.
/// </summary>
internal interface ILayerShellTeardownService
{
    /// <summary>
    /// Destroys the <c>river_layer_shell_seat_v1</c> sub-object associated with the removed seat (if
    /// any) and clears its layer-shell focus state. Safe to call for seats that never had a sub-object.
    /// </summary>
    void TeardownSeat(IntPtr seat);

    /// <summary>
    /// Destroys the <c>river_layer_shell_output_v1</c> sub-object associated with the removed output
    /// (if any) and drops its stored usable-area hint. Safe to call for outputs that never had a
    /// sub-object.
    /// </summary>
    void TeardownOutput(IntPtr output);
}
