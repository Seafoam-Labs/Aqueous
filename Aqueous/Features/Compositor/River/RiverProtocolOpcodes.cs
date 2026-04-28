namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Named opcode constants for the River and core Wayland protocols this client speaks.
/// Each nested class corresponds to a single interface; the constant name matches the
/// event/request name from the upstream protocol XML so that switch arms read as
/// <c>case Manager.Window:</c> rather than <c>case 6:</c>.
/// </summary>
internal static class RiverProtocolOpcodes
{
    /// <summary><c>wl_registry</c> events.</summary>
    internal static class Registry
    {
        internal const uint Global = 0;
        internal const uint GlobalRemove = 1;
    }

    /// <summary><c>river_window_manager_v1</c> events.</summary>
    internal static class Manager
    {
        internal const uint Unavailable = 0;
        internal const uint Finished = 1;
        internal const uint ManageStart = 2;
        internal const uint RenderStart = 3;
        internal const uint SessionLocked = 4;
        internal const uint SessionUnlocked = 5;
        internal const uint WindowInformation = 6;
        internal const uint OutputInformation = 7;
        internal const uint SeatInformation = 8;
    }

    /// <summary><c>river_window_v1</c> events.</summary>
    internal static class Window
    {
        internal const uint Closed = 0;
        internal const uint DimensionsHint = 1;
        internal const uint Dimensions = 2;
        internal const uint AppId = 3;
        internal const uint Title = 4;
        internal const uint Parent = 5;
        internal const uint DecorationHint = 6;
        internal const uint PointerMoveRequested = 7;
        internal const uint PointerResizeRequested = 8;
        internal const uint ShowWindowMenuRequested = 9;
        internal const uint MaximizeRequested = 10;
        internal const uint UnmaximizeRequested = 11;
        internal const uint FullscreenRequested = 12;
        internal const uint ExitFullscreenRequested = 13;
        internal const uint MinimizeRequested = 14;
        internal const uint UnreliablePid = 15;
        internal const uint PresentationHint = 16;
        internal const uint Identifier = 17;
    }

    /// <summary><c>river_output_v1</c> events.</summary>
    internal static class Output
    {
        internal const uint Removed = 0;
        internal const uint WlOutput = 1;
        internal const uint Position = 2;
        internal const uint Dimensions = 3;
    }

    /// <summary><c>river_seat_v1</c> events.</summary>
    internal static class Seat
    {
        internal const uint Removed = 0;
        internal const uint WlSeat = 1;
        internal const uint PointerEnter = 2;
        internal const uint PointerLeave = 3;
        internal const uint WindowInteraction = 4;
        internal const uint ShellSurfaceInteraction = 5;
        internal const uint OpDelta = 6;
        internal const uint OpRelease = 7;
        internal const uint PointerPosition = 8;
    }

    /// <summary><c>river_layer_shell_v1</c> events.</summary>
    internal static class LayerShell
    {
        internal const uint LayerSurface = 0;
    }

    /// <summary>Press/release opcodes shared by River key, pointer and drag bindings.</summary>
    internal static class Binding
    {
        internal const uint Pressed = 0;
        internal const uint Released = 1;
    }
}
