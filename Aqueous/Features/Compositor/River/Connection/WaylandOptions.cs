namespace Aqueous.Features.Compositor.River.Connection;

/// <summary>
/// Options controlling how <see cref="IWaylandConnection"/> opens and
/// drives its <c>wl_display</c> connection. Designed to be bound from
/// configuration (<c>builder.Services.Configure&lt;WaylandOptions&gt;</c>)
/// once the host moves to <c>Microsoft.Extensions.Hosting</c>.
/// </summary>
public sealed class WaylandOptions
{
    /// <summary>
    /// Overrides the <c>WAYLAND_DISPLAY</c> environment variable for the
    /// connect call. <c>null</c> uses libwayland's default behaviour
    /// (read <c>WAYLAND_DISPLAY</c> at connect time).
    /// </summary>
    public string? DisplayName { get; init; }

    /// <summary>
    /// When true, every <c>wl_display_dispatch</c> /
    /// <c>wl_display_roundtrip</c> / <c>wl_display_flush</c> return code
    /// is logged at trace level. Off by default; very chatty.
    /// </summary>
    public bool VerboseProtocolTrace { get; init; }
}
