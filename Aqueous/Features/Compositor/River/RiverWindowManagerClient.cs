using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;
using Aqueous.Features.State;
using Aqueous.Features.Tags;
using Microsoft.Extensions.Logging;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// B1a "survive a session" skeleton that binds the River 0.4+
/// <c>river_window_manager_v1</c> global and keeps the compositor alive by
/// immediately acknowledging every <c>manage_start</c> / <c>render_start</c>
/// event with the corresponding <c>manage_finish</c> / <c>render_finish</c>
/// request.
///
/// <para>
/// <b>This is not a usable window manager.</b> It performs no layout, no
/// focus policy, no keybinding registration, and no decoration placement.
/// Windows will appear at whatever default dimensions River chooses and
/// keyboard focus will behave however River's fallback does in the absence
/// of a WM making focus decisions. The goal is solely to prove that the
/// C# / AOT / hand-rolled protocol stack can bind the global, receive
/// every event type declared in <see cref="WlInterfaces"/>, and keep
/// River's manage/render loop progressing without tripping the
/// <c>sequence_order</c> protocol error or the <c>unresponsive</c> watchdog.
/// </para>
///
/// <para>
/// Gated on the <c>AQUEOUS_RIVER_WM</c> environment variable so that the
/// default Aqueous bar build is unaffected. Set <c>AQUEOUS_RIVER_WM=1</c>
/// to opt in when launching under River as the sole window-management
/// client.
/// </para>
///
/// <para>
/// <b>Safety:</b> A misbehaving window manager can deadlock River (the
/// compositor refuses to render until <c>render_finish</c> is received)
/// and can crash it via protocol errors. This implementation therefore
/// never sends any window-management-state-modifying requests — only the
/// two lifecycle acks required to advance the sequence loop.
/// </para>
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient : IDisposable, TagController.ITagHost
{
    // --- logging -------------------------------------------------------

    /// <summary>
    /// Process-wide <see cref="ILogger"/> for the River feature, lazily
    /// resolved against <see cref="Logging.Factory"/> on first access.
    /// </summary>
    private static readonly ILogger Logger = Logging.For<RiverWindowManagerClient>();

    /// <summary>
    /// All protocol activity funnels through this delegate; the default
    /// implementation routes to <see cref="Logger"/> using a small content
    /// heuristic (messages starting with <c>ERROR</c>/<c>failed</c>/etc map
    /// to <see cref="LogLevel.Error"/>, <c>warn</c>/<c>unavailable</c>
    /// to <see cref="LogLevel.Warning"/>, everything else to
    /// <see cref="LogLevel.Debug"/>). Host code (or tests) may replace it
    /// with a custom sink — call sites stay <c>Log(string)</c> so no
    /// per-site churn is required.
    /// </summary>
    public static Action<string> Log { get; set; } = DefaultLog;

    private static void DefaultLog(string msg)
    {
        var level = ClassifyLogLevel(msg);
#pragma warning disable CA1848, CA2254 // call sites pre-date the structured-logging migration
        Logger.Log(level, "{Message}", msg);
#pragma warning restore CA1848, CA2254
    }

    private static LogLevel ClassifyLogLevel(string msg)
    {
        if (string.IsNullOrEmpty(msg)) return LogLevel.Debug;
        // Quick prefix-based classification; the previous code emitted
        // distinguishing tokens like "ERROR", "failed", "unavailable",
        // "warn" inline — exploit them rather than re-tagging 88 sites.
        if (msg.Contains("ERROR", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("failed", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("could not", StringComparison.OrdinalIgnoreCase))
            return LogLevel.Error;
        if (msg.Contains("warn", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("unavailable", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("giving up", StringComparison.OrdinalIgnoreCase))
            return LogLevel.Warning;
        if (msg.Contains("connected", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("disconnect", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("manage_start", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("session_locked", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("session_unlocked", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("finished", StringComparison.OrdinalIgnoreCase))
            return LogLevel.Information;
        return LogLevel.Debug;
    }

    // --- state tracked from events ------------------------------------
    // WindowEntry / OutputEntry / SeatEntry live in Model/*.cs.

    private readonly ConcurrentDictionary<IntPtr, WindowEntry> _windows = new();
    private readonly ConcurrentDictionary<IntPtr, OutputEntry> _outputs = new();
    private readonly ConcurrentDictionary<IntPtr, SeatEntry> _seats = new();

    // --- interaction service -------------------------------------------

    private readonly SeatInteractionService _seatInteractionService;

    private IntPtr _pendingFocusWindow;
    private IntPtr _pendingFocusShellSurface;
    private IntPtr _pendingFocusSeat;

    private WindowEntry? _activeDragWindow;
    private IntPtr _activeDragSeat;
    private bool _dragFinished;
    private bool _dragStarted;
    private int _dragStartX;
    private int _dragStartY;
    // Resize state — non-zero _dragEdges means the active drag is a resize, not a move.
    // Edges are the river_window_v1 bitfield: top=1, bottom=2, left=4, right=8.
    private uint _dragEdges;
    private int _dragStartW;
    private int _dragStartH;
    // Tracks whether we have already issued inform_resize_start for the current
    // drag so that we know to emit a matching inform_resize_end on finalisation.
    // Without this, libdecor / GTK clients ignore the live propose_dimensions
    // stream during an interactive resize.
    private bool _dragResizeInformed;
    private IntPtr _dragPointerBinding;
    private bool _dragPointerBindingNeedsEnable;
    private readonly ConcurrentDictionary<IntPtr, IntPtr> _seatHoveredWindow = new(); // seat -> window

    // --- wayland state -------------------------------------------------

    /// <summary>
    /// Owns the <c>wl_display*</c> lifetime; everything else in this
    /// file reaches the native display via <see cref="_display"/>, which
    /// proxies to <see cref="WaylandConnection.Display"/>.
    /// </summary>
    private readonly WaylandConnection _connection = new();

    /// <summary>
    /// Drives <c>wl_display_dispatch</c> on a background thread. Started
    /// from <see cref="StartPump"/>, stopped from <see cref="Dispose"/>.
    /// </summary>
    private readonly EventPump _pump;

    private IntPtr _display => _connection.Display;

    /// <summary>
    /// Owns the <c>wl_registry</c> proxy and converts raw
    /// <c>global</c>/<c>global_remove</c> events into the
    /// <see cref="OnGlobalDiscovered"/> handler below.
    /// </summary>
    private readonly RegistryBinder _registry = new();
    private IntPtr _manager;
    private IntPtr _layerShell;
    private IntPtr _xkbBindings;
    private IntPtr _superKeyBinding;

    // --- key bindings -------------------------------------------------

    private readonly Dictionary<IntPtr, KeyBindingAction> _keyBindings = new();

    // For KeyBindingAction.Custom — chord proxy → free-form action verb.
    private readonly Dictionary<IntPtr, string> _customBindingActions = new();


    private IntPtr _primarySeat;
    private IntPtr _focusedWindow;
    private bool _insideManageSequence;
    private uint _managerVersion;
    private GCHandle _selfHandle;

    // --- layout subsystem ----------------------------------------------
    // Pluggable layout engine (Phase 1.1 / B1b). The controller owns
    // per-output state and applies size hints; the engines themselves are
    // pure functions that never call into Wayland.
    private readonly LayoutRegistry _layoutRegistry;
    private LayoutController _layoutController;
    private LayoutConfig _layoutConfig;

    // --- tags subsystem (Phase B1c) -----------------------------------
    private readonly TagController _tagController;

    // --- window-state subsystem (Phase B1e — Pass B) ------------------
    // Per-window state projection (FS/Max/Float/Min/Scratchpad) used by
    // WindowStateController. Lazily populated when a chord first
    // touches a window; lifecycle-cleared on close / output removal.
    private readonly ConcurrentDictionary<IntPtr, WindowStateData> _windowStates = new();

    // Per-output single-FS slot (single-fullscreen-per-output rule).
    private readonly ConcurrentDictionary<IntPtr, IntPtr> _outputFullscreen = new();
    private readonly ScratchpadRegistry _scratchpadRegistry;
    private readonly WindowStateController _windowState;

    private RiverWindowManagerClient()
    {
        _pump = new EventPump(_connection, msg => Log(msg));
        _seatInteractionService = new SeatInteractionService(this);
        _layoutRegistry = new LayoutRegistry();
        _layoutConfig = LayoutConfig.Load(GetDefaultConfigPath());
        _layoutController = new LayoutController(_layoutRegistry, _layoutConfig);
        _tagController = new TagController(this);
        _scratchpadRegistry = new ScratchpadRegistry();
        _windowState = new WindowStateController(
            new RiverWindowStateHost(this), _scratchpadRegistry);

        // Push libinput config to the privileged sidecar (aqueous-inputd).
        // Best-effort: silently logs and proceeds if the daemon isn't up.
        // River 0.4 owns libinput but exposes no API to a WM client, so
        // pointer accel etc. can only be applied out-of-process. Mirrors
        // niri's "apply on startup + on config reload" model — the same
        // call lives in ReloadConfig (KeyBindingActionRouter).
        InputDaemonClient.Apply(_layoutConfig.Input);
    }

    private static string GetDefaultConfigPath()
    {
        // ~/.config/aqueous/wm.toml — XDG base dir if set, otherwise HOME.
        var xdg = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
        var baseDir = !string.IsNullOrEmpty(xdg)
            ? xdg
            : System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".config");
        return System.IO.Path.Combine(baseDir, "aqueous", "wm.toml");
    }

    // --- lifecycle -----------------------------------------------------

    /// <summary>
    /// Starts the client if <c>AQUEOUS_RIVER_WM=1</c> and the WM global
    /// is advertised to us. Returns a <see cref="Result{T}"/> carrying
    /// either the live client or a human-readable failure description.
    /// The optional <paramref name="cancellationToken"/> is plumbed
    /// through to the event-pump so a process-wide SIGINT/SIGTERM can
    /// shut the client down cleanly.
    /// </summary>
    public static Result<RiverWindowManagerClient> TryStart(CancellationToken cancellationToken = default)
    {
        if (Environment.GetEnvironmentVariable("AQUEOUS_RIVER_WM") != "1")
        {
            return Result<RiverWindowManagerClient>.Fail(
                "AQUEOUS_RIVER_WM is not set to 1; refusing to attach as a window manager");
        }

        try
        {
            var c = new RiverWindowManagerClient();
            var connected = c.Connect();
            if (!connected.IsOk)
            {
                c.Dispose();
                return Result<RiverWindowManagerClient>.Fail(connected.Error!);
            }

            c.StartPump(cancellationToken);
            Log($"attached as window manager (v{c._managerVersion})");
            return Result<RiverWindowManagerClient>.Ok(c);
        }
        catch (DllNotFoundException e)
        {
            return Result<RiverWindowManagerClient>.Fail(
                "libwayland-client could not be loaded: " + e.Message);
        }
        catch (Exception e)
        {
            Log("TryStart failed: " + e.Message);
            return Result<RiverWindowManagerClient>.Fail("TryStart threw: " + e.Message);
        }
    }

    private Result Connect()
    {
        var connectResult = _connection.Connect();
        if (!connectResult.IsOk)
        {
            Log("wl_display_connect failed: " + connectResult.Error);
            return connectResult;
        }

        WlInterfaces.EnsureBuilt();

        _selfHandle = GCHandle.Alloc(this, GCHandleType.Normal);
        IntPtr dispatcher = (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch;

        if (!_registry.Create(_display, dispatcher, GCHandle.ToIntPtr(_selfHandle)))
        {
            Log("get_registry failed");
            return Result.Fail("wl_display_get_registry returned null");
        }

        _registry.Discovered += OnGlobalDiscovered;

        // Flush globals; then a second roundtrip so any events the
        // compositor sends immediately on bind (for an existing window
        // list) are delivered before we return.
        _connection.Roundtrip();
        _connection.Roundtrip();

        if (_manager == IntPtr.Zero)
        {
            return Result.Fail(
                "river_window_manager_v1 global was not advertised — is River 0.4+ running with WM support?");
        }
        return Result.Ok;
    }

    private void StartPump(CancellationToken cancellationToken = default) =>
        _pump.Start(cancellationToken);

    public void Dispose()
    {
        // river_window_manager_v1::stop (opcode 0) is intentionally NOT
        // sent here: it is not a destructor — we'd still have to wait
        // for the `finished` event and then call destroy. For the
        // skeleton we just disconnect the display; River treats a
        // disconnected WM the same way as a stopped one and cleans up.
        try
        {
            _pump.Stop();
            _connection.Disconnect();
        }
        catch
        {
            // Tear-down is best-effort; we never want Dispose to throw.
        }
        finally
        {
            if (_selfHandle.IsAllocated)
            {
                _selfHandle.Free();
            }
        }
    }


    // --- registry ------------------------------------------------------

    private void OnGlobalDiscovered(RegistryGlobal global)
    {
        // The set of interfaces this client cares about. Anything else
        // advertised by the compositor is intentionally ignored.
        if (global.Interface == "river_window_manager_v1" && _manager == IntPtr.Zero)
        {
            _managerVersion = Math.Min(global.Version, 4u);
            _manager = _registry.Bind(global.Name, WlInterfaces.RiverWindowManager, _managerVersion);
            if (_manager != IntPtr.Zero)
            {
                WaylandInterop.wl_proxy_add_dispatcher(
                    _manager,
                    (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch,
                    GCHandle.ToIntPtr(_selfHandle),
                    IntPtr.Zero);
                Log($"bound river_window_manager_v1 (version {_managerVersion})");
            }
        }
        else if (global.Interface == "river_layer_shell_v1")
        {
            _layerShell = _registry.Bind(global.Name, WlInterfaces.RiverLayerShell, 1);
            WaylandInterop.wl_proxy_add_dispatcher(
                _layerShell,
                (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch,
                GCHandle.ToIntPtr(_selfHandle),
                IntPtr.Zero);
            Log("bound river_layer_shell_v1");
        }
        else if (global.Interface == "river_xkb_bindings_v1")
        {
            uint xkbVersion = Math.Min(global.Version, 2u);
            _xkbBindings = _registry.Bind(global.Name, WlInterfaces.RiverXkbBindings, xkbVersion);
            Log($"bound river_xkb_bindings_v1 (version {xkbVersion})");
        }
    }





}
