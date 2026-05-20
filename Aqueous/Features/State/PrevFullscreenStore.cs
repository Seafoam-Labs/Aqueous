using System;
using System.Collections.Generic;

namespace Aqueous.Features.State;

/// <summary>
/// PR 9.12 §2.13 Step 4 — DI singleton replacing
/// <c>RiverWindowManagerClient._prevFullscreenHandles</c>.
///
/// Snapshot of window handles that were in the fullscreen bucket on
/// the previous <c>ProposeForArea</c> cycle. On the cycle a window
/// leaves the FS bucket (unfullscreen) the layout proposer must
/// force a re-propose because the tiled/floating bucket may compute
/// the same pixel rect as the FS rect, leaving <c>LastHintW/H</c>
/// unchanged and no <c>propose_dimensions</c> emitted — which makes
/// the client appear stuck at the FS size.
///
/// <para>
/// Accessed only from the manage-cycle thread (pump thread), so a
/// plain <see cref="HashSet{T}"/> is fine.
/// </para>
/// </summary>
internal sealed class PrevFullscreenStore
{
    public HashSet<IntPtr> Handles { get; } = new();
}
