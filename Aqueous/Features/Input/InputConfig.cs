namespace Aqueous.Features.Input;

/// <summary>
/// Input configuration parsed from <c>[input]</c> (and the per-device sub-tables
/// <c>[input.mouse]</c>, <c>[input.touchpad]</c>, <c>[input.trackpoint]</c>) in <c>wm.toml</c>.
/// <para>
/// The schema mirrors niri's KDL <c>input { mouse { … } }</c> block so users can copy values
/// between configs. <see cref="FocusFollowsMouse"/> is honoured in-process by the WM client (see
/// <c>SeatEventHandler</c>); the libinput knobs in <see cref="PerDeviceInput"/> are pushed
/// directly to the compositor's own libinput context via the <c>river_libinput_config_v1</c>
/// Wayland protocol (see <see cref="LibinputConfigApplier"/>).
/// </para>
/// <para>
/// flat keys <see cref="PointerAcceleration"/> / <see cref="PointerAccelerationFactor"/> are kept
/// for backwards compatibility — they map to <c>Mouse.AccelProfile</c> / <c>Mouse.AccelSpeed</c>
/// at apply time when the dedicated per-device sub-table is omitted.
/// </para>
/// </summary>
public sealed record InputConfig
{
    /// <summary>
    /// Sloppy focus: hover-to-focus when true.
    /// </summary>
    public bool FocusFollowsMouse { get; init; }

    /// <summary>
    /// Mouse-accel flag: true → <c>adaptive</c> profile, false → <c>flat</c>. Use <see
    /// cref="Mouse"/>.<see cref="PerDeviceInput.AccelProfile"/> for explicit control.
    /// </summary>
    public bool PointerAcceleration { get; init; }

    /// <summary>
    /// Mouse-accel speed bias in <c>[-1.0, 1.0]</c>. Default 0.0 matches libinput's neutral. Use <see
    /// cref="Mouse"/>.<see cref="PerDeviceInput.AccelSpeed"/> for explicit control.
    /// </summary>
    public double PointerAccelerationFactor { get; init; } = 0.0;

    /// <summary>
    /// Per-device libinput config for plain mice / pointers.
    /// </summary>
    public PerDeviceInput Mouse { get; init; } = new();

    /// <summary>
    /// Per-device libinput config for touchpads.
    /// </summary>
    public PerDeviceInput Touchpad { get; init; } = new();

    /// <summary>
    /// Per-device libinput config for trackpoints.
    /// </summary>
    public PerDeviceInput Trackpoint { get; init; } = new();

    /// <summary>
    /// XKB layout(s), e.g. <c>"us"</c> or <c>"us,de"</c>. Null → compositor default
    /// (xkbcommon honours <c>XKB_DEFAULT_LAYOUT</c>). Pushed to the compositor via
    /// <c>river_xkb_config_v1</c>.
    /// </summary>
    public string? XkbLayout { get; init; }

    /// <summary>
    /// XKB variant, e.g. <c>"dvorak"</c>. Null → none.
    /// </summary>
    public string? XkbVariant { get; init; }

    /// <summary>
    /// XKB options, e.g. <c>"caps:escape"</c>. Null → none.
    /// </summary>
    public string? XkbOptions { get; init; }

    public static InputConfig Default { get; } = new();
}

/// <summary>
/// Per-device libinput configuration. All fields are nullable so the daemon can distinguish "user
/// set this" from "leave libinput's default". Field semantics map 1:1 to
/// <c>libinput_device_config_*</c> setters.
/// </summary>
public sealed record PerDeviceInput
{
    /// <summary>
    /// <c>"adaptive"</c> | <c>"flat"</c>; null → libinput default.
    /// </summary>
    public string? AccelProfile { get; init; }

    /// <summary>
    /// Speed bias in <c>[-1.0, 1.0]</c>; null → libinput default (0.0).
    /// </summary>
    public double? AccelSpeed { get; init; }

    /// <summary>
    /// Reverse scroll direction (touchpads + wheel mice).
    /// </summary>
    public bool? NaturalScroll { get; init; }

    /// <summary>
    /// Tap-to-click (touchpads only).
    /// </summary>
    public bool? Tap { get; init; }

    /// <summary>
    /// Disable-while-typing (touchpads only).
    /// </summary>
    public bool? Dwt { get; init; }

    /// <summary>
    /// Left-handed button mapping (swap left/right).
    /// </summary>
    public bool? LeftHanded { get; init; }

    /// <summary>
    /// <c>"clickfinger"</c> | <c>"button-areas"</c> (touchpads).
    /// </summary>
    public string? ClickMethod { get; init; }

    /// <summary>
    /// <c>"two-finger"</c> | <c>"edge"</c> | <c>"no-scroll"</c> (touchpads).
    /// </summary>
    public string? ScrollMethod { get; init; }

    /// <summary>
    /// Middle-click emulation (chord left+right → middle).
    /// </summary>
    public bool? MiddleEmulation { get; init; }
}
