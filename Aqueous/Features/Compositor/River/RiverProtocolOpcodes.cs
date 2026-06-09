namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Named opcode constants for the River and core Wayland protocols this client speaks. Each nested
/// class corresponds to a single interface; the constant name matches the event/request name from
/// the upstream protocol XML so that switch arms read as <c>case Manager.Window:</c> rather than
/// <c>case 6:</c>.
/// </summary>
internal static class RiverProtocolOpcodes
{
    /// <summary>
    /// <c>wl_registry</c> Events.
    /// </summary>
    internal static class Registry
    {
        internal const uint Global = 0;
        internal const uint GlobalRemove = 1;
    }

    /// <summary>
    /// <c>river_window_manager_v1</c> Events.
    /// </summary>
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

    /// <summary>
    /// <c>river_window_v1</c> Events.
    /// </summary>
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
        internal const uint ActivateRequested = 18;
        internal const uint UnminimizeRequested = 19;

        /// <summary>
        /// <c>set_workspace</c> request opcode (since v6). Added as the last request so existing
        /// request opcodes are unchanged.
        /// </summary>
        internal const uint SetWorkspace = 24;
    }

    /// <summary>
    /// <c>ext_workspace_manager_v1</c> opcodes.
    /// </summary>
    internal static class ExtWorkspaceManager
    {
        // Events.
        internal const uint WorkspaceGroup = 0;
        internal const uint Workspace = 1;
        internal const uint Done = 2;
        internal const uint Finished = 3;

        // Requests.
        internal const uint Commit = 0;
        internal const uint Stop = 1;
    }

    /// <summary>
    /// <c>ext_workspace_group_handle_v1</c> opcodes.
    /// </summary>
    internal static class ExtWorkspaceGroup
    {
        // Events.
        internal const uint Capabilities = 0;
        internal const uint OutputEnter = 1;
        internal const uint OutputLeave = 2;
        internal const uint WorkspaceEnter = 3;
        internal const uint WorkspaceLeave = 4;
        internal const uint Removed = 5;

        // Requests.
        internal const uint CreateWorkspace = 0;
        internal const uint Destroy = 1;
    }

    /// <summary>
    /// <c>ext_workspace_handle_v1</c> opcodes plus the <c>state</c> bitfield.
    /// </summary>
    internal static class ExtWorkspaceHandle
    {
        // Events.
        internal const uint Id = 0;
        internal const uint Name = 1;
        internal const uint Coordinates = 2;
        internal const uint State = 3;
        internal const uint Capabilities = 4;
        internal const uint Removed = 5;

        // Requests.
        internal const uint Destroy = 0;
        internal const uint Activate = 1;
        internal const uint Deactivate = 2;
        internal const uint Assign = 3;
        internal const uint Remove = 4;

        // state bitfield.
        internal const uint StateActive = 1;
        internal const uint StateUrgent = 2;
        internal const uint StateHidden = 4;
    }

    /// <summary>
    /// <c>river_output_v1</c> Events.
    /// </summary>
    internal static class Output
    {
        internal const uint Removed = 0;
        internal const uint WlOutput = 1;
        internal const uint Position = 2;
        internal const uint Dimensions = 3;
    }

    /// <summary>
    /// <c>river_seat_v1</c> Events.
    /// </summary>
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

    /// <summary>
    /// <c>river_layer_shell_v1</c> Request opcodes (new shape).
    /// </summary>
    internal static class LayerShell
    {
        internal const uint Destroy = 0;
        internal const uint GetOutput = 1;
        internal const uint GetSeat = 2;
    }

    /// <summary>
    /// <c>river_layer_shell_output_v1</c> Request/event opcodes (numbered independently).
    /// </summary>
    internal static class LayerShellOutput
    {
        internal const uint NonExclusiveArea = 0; // event
        internal const uint Destroy = 0;          // request
        internal const uint SetDefault = 1;       // request
    }

    /// <summary>
    /// <c>river_layer_shell_seat_v1</c> Request/event opcodes (numbered independently).
    /// </summary>
    internal static class LayerShellSeat
    {
        internal const uint FocusExclusive = 0;    // event
        internal const uint FocusNonExclusive = 1; // event
        internal const uint FocusNone = 2;         // event
        internal const uint Destroy = 0;           // request
    }

    /// <summary>
    /// <c>river_shell_surface_v1</c> Event opcodes.
    /// </summary>
    internal static class ShellSurface
    {
        internal const uint Destroyed = 0; // since v5
    }

    /// <summary>
    /// Press/release opcodes shared by River key, pointer and drag bindings.
    /// </summary>
    internal static class Binding
    {
        internal const uint Pressed = 0;
        internal const uint Released = 1;
    }

    /// <summary>
    /// <c>wl_shm</c> Request opcodes.
    /// </summary>
    internal static class WlShm
    {
        internal const uint CreatePool = 0;
    }

    /// <summary>
    /// <c>wl_shm_pool</c> Request opcodes.
    /// </summary>
    internal static class WlShmPool
    {
        internal const uint CreateBuffer = 0;
        internal const uint Destroy = 1;
        internal const uint Resize = 2;
    }

    /// <summary>
    /// <c>wl_buffer</c> Request / event opcodes.
    /// </summary>
    internal static class WlBuffer
    {
        internal const uint Destroy = 0;       // request
        internal const uint Release = 0;       // event
    }

    /// <summary>
    /// <c>zwlr_screencopy_manager_v1</c> Request opcodes.
    /// </summary>
    internal static class ScreencopyManager
    {
        internal const uint CaptureOutput = 0;
        internal const uint CaptureOutputRegion = 1;
        internal const uint Destroy = 2;
    }

    /// <summary>
    /// <c>zwlr_screencopy_frame_v1</c> Request opcodes.
    /// </summary>
    internal static class ScreencopyFrameRequest
    {
        internal const uint Copy = 0;
        internal const uint Destroy = 1;
        internal const uint CopyWithDamage = 2;
    }

    /// <summary>
    /// <c>river_libinput_config_v1</c> Event opcodes.
    /// </summary>
    internal static class LibinputConfig
    {
        internal const uint Finished = 0;
        internal const uint LibinputDevice = 1;
    }

    /// <summary>
    /// <c>river_libinput_device_v1</c> Request opcodes. Only the four actually used by
    /// <c>LibinputConfigApplier</c> are listed; the full request table lives in <see
    /// cref="WlInterfaces"/>.
    /// </summary>
    internal static class LibinputDeviceRequest
    {
        internal const uint Destroy           = 0;
        internal const uint SetTap            = 2;
        internal const uint SetAccelProfile   = 8;
        internal const uint SetAccelSpeed     = 9;
        internal const uint SetNaturalScroll  = 11;
    }

    /// <summary>
    /// <c>river_libinput_device_v1</c> Event opcodes. Only the events
    /// <c>LibinputConfigApplier</c>/<c>LibinputDeviceEventHandler</c> actually inspect are listed;
    /// every other event is silently dropped by the handler.
    /// </summary>
    internal static class LibinputDeviceEvent
    {
        internal const uint Removed     = 0;
        internal const uint TapSupport  = 5;
        internal const uint Done        = 55;
    }

    /// <summary>
    /// <c>river_libinput_device_v1</c> <c>accel_profile</c> enum mirroring the protocol's values.
    /// </summary>
    internal static class LibinputAccelProfile
    {
        internal const uint None     = 0;
        internal const uint Flat     = 1;
        internal const uint Adaptive = 2;
        internal const uint Custom   = 4;
    }

    /// <summary>
    /// <c>zwlr_screencopy_frame_v1</c> Event opcodes.
    /// </summary>
    internal static class ScreencopyFrame
    {
        internal const uint Buffer = 0;
        internal const uint Flags = 1;
        internal const uint Ready = 2;
        internal const uint Failed = 3;
        internal const uint Damage = 4;
        internal const uint LinuxDmabuf = 5;
        internal const uint BufferDone = 6;
    }
}
