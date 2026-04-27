using System;

namespace Aqueous.Features.Tags;

/// <summary>
/// Constants and helpers for the WM-internal tag bitmask model.
///
/// <para>
/// Each output owns a 32-bit <c>VisibleTags</c> mask describing which tags
/// it currently shows. Each managed window owns a 32-bit <c>Tags</c> mask
/// describing which tags it belongs to. A window is visible on its
/// assigned output iff <c>(window.Tags &amp; output.VisibleTags) != 0</c>.
/// </para>
///
/// <para>
/// <b>Note:</b> The <c>river_window_v1</c> protocol shipped in this
/// codebase (see <c>WlInterfaces.cs</c>) does <i>not</i> expose a
/// <c>set_tags</c> request. Tags are therefore implemented as a
/// WM-internal logical model: visibility transitions are pushed down to
/// the compositor through the existing <c>hide</c> (opcode 4) and
/// <c>show</c> (opcode 5) requests on <c>river_window_v1</c>. Should a
/// future protocol bump add <c>set_tags</c>, the same mask can be
/// forwarded to the compositor without restructuring this layer.
/// </para>
/// </summary>
public static class TagState
{
    /// <summary>"All tags" sentinel — used by Super+0 to view every tag.</summary>
    public const uint AllTags = 0xFFFFFFFFu;

    /// <summary>
    /// Reserved scratchpad bit. Phase B1c reserves it; full scratchpad
    /// semantics are deferred to Phase B1e. Windows are never auto-tagged
    /// onto this bit at <c>manage_start</c>.
    /// </summary>
    public const uint ScratchpadTag = 1u << 31;

    /// <summary>Default tag for a freshly-managed window when no other hint exists.</summary>
    public const uint DefaultTag = 1u;

    /// <summary>Returns a single-bit mask for the 0-based tag index <paramref name="n"/>.</summary>
    public static uint Bit(int n)
    {
        if (n < 0 || n > 31) throw new ArgumentOutOfRangeException(nameof(n));
        return 1u << n;
    }

    /// <summary>True iff the window is visible under the output's current view.</summary>
    public static bool IsVisible(uint windowTags, uint outputVisible) =>
        (windowTags & outputVisible) != 0u;
}
