namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Stable identifier for every built-in chord action that
/// <see cref="RiverWindowManagerClient"/> can dispatch. Promoted out of
/// the nested-enum declaration during the Phase 2 readability refactor
/// — values and ordering are unchanged.
/// </summary>
/// <remarks>
/// Tag actions (<c>ViewTag1..ViewTag9</c>, <c>SendTag1..SendTag9</c>,
/// <c>ToggleViewTag1..</c>, <c>ToggleWindowTag1..</c>) are
/// intentionally laid out as contiguous ranges so the dispatcher can
/// compute the tag mask from
/// <c>1u &lt;&lt; (action - ViewTag1)</c>. <c>Tag10</c> is bound to the
/// digit key '0' to mirror keymap order <c>1234567890</c>.
/// </remarks>
internal enum KeyBindingAction
{
    ToggleStartMenu,
    SpawnTerminal,
    CloseFocused,
    CycleFocus,
    FocusLeft,
    FocusRight,
    FocusDown,
    FocusUp,
    ScrollViewportLeft,
    ScrollViewportRight,
    MoveColumnLeft,
    MoveColumnRight,
    ReloadConfig,
    SetLayoutPrimary,
    SetLayoutSecondary,
    SetLayoutTertiary,
    SetLayoutQuaternary,

    // Phase B1c — Tag actions. Indexed by 0-based tag bit (0..9
    // for tag1..10) so the dispatcher can compute the mask via
    // 1u << (action - ViewTag1). Tag10 is bound to the digit
    // key '0' because keymaps order digits 1234567890.
    ViewTag1,
    ViewTag2,
    ViewTag3,
    ViewTag4,
    ViewTag5,
    ViewTag6,
    ViewTag7,
    ViewTag8,
    ViewTag9,
    ViewTagAll,
    SendTag1,
    SendTag2,
    SendTag3,
    SendTag4,
    SendTag5,
    SendTag6,
    SendTag7,
    SendTag8,
    SendTag9,
    SendTagAll,
    ToggleViewTag1,
    ToggleViewTag2,
    ToggleViewTag3,
    ToggleViewTag4,
    ToggleViewTag5,
    ToggleViewTag6,
    ToggleViewTag7,
    ToggleViewTag8,
    ToggleViewTag9,
    ToggleWindowTag1,
    ToggleWindowTag2,
    ToggleWindowTag3,
    ToggleWindowTag4,
    ToggleWindowTag5,
    ToggleWindowTag6,
    ToggleWindowTag7,
    ToggleWindowTag8,
    ToggleWindowTag9,
    SwapLastTagset,

    // Phase B1e — Window state ops (Pass B integration).
    ToggleFullscreen,
    ToggleMaximize,
    ToggleFloating,
    ToggleMinimize,
    UnminimizeLast,
    ToggleScratchpad,
    SendToScratchpad,
    Custom,
}
