using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;
using Aqueous.Features.Startup;
using Aqueous.Features.State;
using Aqueous.Features.Tags;
using Microsoft.Extensions.Logging;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// B1a "survive a session" skeleton that binds the RiverDelta
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
internal sealed unsafe partial class RiverWindowManagerClient : IDisposable
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

    // Step 10 (sub-steps 4-6) of the IWindowRegistry / IOutputRegistry /
    // ISeatRegistry plan: the three per-entity dictionaries are owned by
    // the corresponding registry singletons. All partial-class siblings
    // (Layout / Tags / Focus / SnapZones / Dispatch event handlers /
    // WindowStateHost) now access them via _windowRegistry.Entries /
    // _outputRegistry.Entries / _seatRegistry.Entries directly; the
    // previous _windows / _outputs / _seats shim properties were deleted
    // when the migration completed. New code should prefer the typed
    // _windowRegistry.Track / Untrack / TryGet / Snapshot API where the
    // call site does not need raw dictionary semantics.

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

    // Second pointer binding for Super+RMB drag-to-resize (Option 3 plan).
    // Lets the WM initiate resize on undecorated/SSD-expecting clients
    // (alacritty, Firefox without libdecor, …) by deriving _dragEdges from
    // the pointer's quadrant inside the focused window, then arming the
    // same drag pipeline that pointer_resize_requested uses.
    private IntPtr _dragResizePointerBinding;
    private bool _dragResizePointerBindingNeedsEnable;

    // SnapZones activator pointer bindings (one per distinct activator
    // modifier configured in [[snapzones]]). River pointer bindings carry
    // a static modifier mask, so live mod-state during a drag is not
    // observable: instead, we register an additional Super+<activator>+
    // BTN_LEFT binding for each activator the user requests, and remember
    // which one fired the active drag. The SnapZones gate then matches
    // the drag's activator against the per-layout Activator field.
    //
    // Map: pointer-binding proxy → SnapActivator value it was registered
    // with. Lookups happen in the drag dispatcher (which already routes
    // by proxy). Empty when no activator-gated layouts are configured.
    private readonly Dictionary<IntPtr, Aqueous.Features.SnapZones.SnapActivator> _snapActivatorBindings = new();

    private readonly Dictionary<IntPtr, bool> _snapActivatorBindingNeedsEnable = new();

    // Activator that armed the currently-active drag. Always for the
    // plain Super+LMB binding; Shift/Ctrl/Alt for the snap-activator
    // bindings; reset to Always on drag-release. Read by
    // TryResolveSnapForDrag to gate snapping per layout.
    private Aqueous.Features.SnapZones.SnapActivator _activeDragActivator =
        Aqueous.Features.SnapZones.SnapActivator.Always;

    private readonly ConcurrentDictionary<IntPtr, IntPtr> _seatHoveredWindow = new(); // seat -> window

    // Latest pointer position per seat in the compositor's logical
    // coordinate space, updated from river_seat_v1::pointer_position. Used
    // by the Super+RMB drag-resize binding to determine which corner of
    // the focused window the user clicked on.
    private readonly ConcurrentDictionary<IntPtr, (int X, int Y)> _seatPointerPos = new();

    // --- wayland state -------------------------------------------------

    /// <summary>
    /// Owns the <c>wl_display*</c> lifetime; everything else in this
    /// file reaches the native display via <see cref="_display"/>, which
    /// proxies to <see cref="IWaylandConnection.Display"/>.
    /// </summary>
    private readonly IWaylandConnection _connection;

    // Registry seams (Phase 2 readability refactor — DI step).
    // Owned by the DI container; the parameterless ctor falls back to
    // freshly-allocated instances so unit tests and the legacy code
    // path keep working. The previous _windows / _outputs / _seats shim
    // properties have been removed — every partial-class call site now
    // reads / writes the registries directly via .Entries (raw
    // ConcurrentDictionary semantics) or, where applicable, the typed
    // Track / Untrack / TryGet / Snapshot API.
    private readonly IWindowRegistry _windowRegistry;
    private readonly IOutputRegistry _outputRegistry;
    private readonly ISeatRegistry _seatRegistry;

    /// <summary>
    /// Drives <c>wl_display_dispatch</c> on a background thread. Started
    /// from <see cref="StartPump"/>, stopped from <see cref="Dispose"/>.
    /// Consumed via the <see cref="IEventPump"/> seam so the pump can
    /// be replaced or faked in tests; the field is upcast to the
    /// interface to keep this class from reaching into pump internals.
    /// </summary>
    private readonly IEventPump _pump;

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
    private uint _xkbBindingsVersion;
    private IntPtr _superKeyBinding;

    // --- screencopy (wlr-screencopy-unstable-v1) ----------------------
    //
    // Bound opportunistically when RiverDelta advertises both
    // `wl_shm` and `zwlr_screencopy_manager_v1`. We deliberately do NOT
    // bind a `wl_output` proxy here: a real bind delivers a flurry of
    // standard wl_output events (geometry/mode/scale/name/description/
    // done) to the WM's display, and any descriptor mismatch tears down
    // the connection — which once silently broke window mapping. Instead
    // we cache the registry `RegistryGlobal` for each advertised
    // wl_output and bind on-demand inside the capture path, then
    // destroy the proxy as soon as the frame finishes.
    private IntPtr _wlShm;
    private IntPtr _screencopyManager;
    private uint _screencopyVersion;
    private WlrScreencopyClient? _screencopy;
    private readonly ConcurrentDictionary<uint, RegistryGlobal> _wlOutputGlobals = new();

    // --- key bindings -------------------------------------------------

    private readonly Dictionary<IntPtr, KeyBindingAction> _keyBindings = new();

    // --- Stage 0 of god-class decomposition: proxy → interface name ---
    //
    // The native [UnmanagedCallersOnly] callback in ProxyDispatcher.cs
    // currently routes events by raw `target` (IntPtr) identity against
    // the dictionaries scattered throughout this class. Stage 0 of the
    // decomposition plan introduces a parallel `IntPtr → interface name`
    // map populated at every proxy-bind site. It is intentionally
    // write-only for now: Stage 8 will be the first reader, when the
    // native callback is rewritten to construct WlEvent.InterfaceName
    // by looking up the firing proxy here and then delegating to
    // IEventDispatcher.Dispatch.
    //
    // Routing today still goes through ProxyDispatcher's if/else chain,
    // so populating this map cannot break dispatch — at worst a missed
    // population would surface as a no-op lookup in Stage 8.
    //
    // Single-threaded by construction: every populating site runs
    // either on the connect thread (registry binds) or on the pump
    // thread (handler-driven binds), never both concurrently. Backed
    // by ProxyInterfaceMap so the population logic is unit-testable
    // without needing to construct a god-class instance.
    private readonly Aqueous.Features.Compositor.River.Dispatch.ProxyInterfaceMap _proxyInterface = new();

    /// <summary>
    /// Record the Wayland interface name of a freshly bound proxy.
    /// Tolerant of <see cref="IntPtr.Zero"/> and null/empty names so
    /// call sites can invoke it immediately after
    /// <c>wl_proxy_marshal_flags</c> without an inline null check.
    /// </summary>
    internal void TrackProxyInterface(IntPtr proxy, string interfaceName)
    {
        _proxyInterface.Track(proxy, interfaceName);
    }

    /// <summary>Test/diagnostic accessor: number of proxies currently tracked.</summary>
    internal int TrackedProxyCount => _proxyInterface.Count;

    /// <summary>Test/diagnostic accessor: lookup the recorded interface name.</summary>
    internal string? TryGetProxyInterface(IntPtr proxy) => _proxyInterface.TryGet(proxy);

    // For KeyBindingAction.Custom — chord proxy → free-form action verb.
    private readonly Dictionary<IntPtr, string> _customBindingActions = new();


    private IntPtr _primarySeat;
    private IntPtr _focusedWindow;
    // Stage 5: backing for the manage-cycle flush flag now lives on
    // IManagerRequestSender. The property below preserves the original
    // field name for the many partial/handler call sites that still
    // read/write it directly; deleted in Stage 9 when those call sites
    // route through the interface.
    private bool _insideManageSequence
    {
        get => _managerRequestSender.InsideManageSequence;
        set => _managerRequestSender.InsideManageSequence = value;
    }
    private uint _managerVersion;
    private GCHandle _selfHandle;

    // Stage 5: Wayland-send seam. Owned by this class for lifetime
    // management; Init() is called from OnGlobalDiscovered once the
    // river_window_manager_v1 proxy has been bound.
    private readonly Aqueous.Features.Layout.IManagerRequestSender _managerRequestSender =
        new Aqueous.Features.Layout.ManagerRequestSender();

    // Stage 5: ILayoutProposer facade — a thin delegate over the
    // existing LayoutProposer partial. The 762-line math/state
    // migration is deferred to Stage 5b; the seam exists today only
    // so FocusService + future handlers can take the interface as a
    // constructor dependency.
    private readonly Aqueous.Features.Layout.ILayoutProposer _layoutProposer;

    // --- layout subsystem ----------------------------------------------
    // Pluggable layout engine (Phase 1.1 / B1b). The controller owns
    // per-output state and applies size hints; the engines themselves are
    // pure functions that never call into Wayland.
    private readonly LayoutRegistry _layoutRegistry;
    private LayoutController _layoutController;
    private LayoutConfig _layoutConfig;

    // --- focus subsystem (Stage 4) ------------------------------------
    private readonly Aqueous.Features.Focus.IFocusService _focusService;

    // --- tags subsystem (Phase B1c) -----------------------------------
    private readonly ITagService _tagController;

    // --- window-state subsystem (Phase B1e — Pass B) ------------------
    // Per-window state projection (FS/Max/Float/Min/Scratchpad) used by
    // WindowStateController. Lazily populated when a chord first
    // touches a window; lifecycle-cleared on close / output removal.
    private readonly ConcurrentDictionary<IntPtr, WindowStateData> _windowStates = new();

    // Per-output single-FS slot (single-fullscreen-per-output rule).
    private readonly ConcurrentDictionary<IntPtr, IntPtr> _outputFullscreen = new();

    // Fix #3: snapshot of window handles that were in the fullscreen bucket on
    // the previous ProposeForArea cycle. On the cycle a window leaves the FS
    // bucket (unfullscreen) we must force a re-propose because the tiled/
    // floating bucket may compute the same pixel rect as the FS rect, leaving
    // LastHintW/H unchanged and no propose_dimensions emitted — which makes the
    // client appear stuck at the FS size. Accessed only from the manage cycle
    // thread (ProposeForArea), so a plain HashSet is fine.
    private readonly HashSet<IntPtr> _prevFullscreenHandles = new();
    private readonly ScratchpadRegistry _scratchpadRegistry;

    private readonly WindowStateController _windowState;

    // Phase B1f: [[exec]] autostart runner. Owns the once/restart state for
    // the supervised commands listed in wm.toml; fired after the initial
    // roundtrip in Connect().
    private readonly StartupExecRunner _startupExec;
    private readonly RiverWindowStateHost _stateHost;

    private RiverWindowManagerClient()
        : this(
            new WaylandConnection(),
            new WindowRegistry(),
            new OutputRegistry(),
            new SeatRegistry(),
            pump: null)
    {
    }

    private RiverWindowManagerClient(
        IWaylandConnection connection,
        IWindowRegistry windowRegistry,
        IOutputRegistry outputRegistry,
        ISeatRegistry seatRegistry,
        IEventPump? pump)
    {
        _connection = connection;
        _windowRegistry = windowRegistry;
        _outputRegistry = outputRegistry;
        _seatRegistry = seatRegistry;
        _pump = pump ?? new EventPump(
            _connection,
            Diagnostics.Logging.For<EventPump>(),
            new EventPumpOptions());
        _seatInteractionService = new SeatInteractionService(this);
        _layoutRegistry = new LayoutRegistry();
        _layoutConfig = LayoutConfig.Load(GetDefaultConfigPath());
        _layoutController = new LayoutController(_layoutRegistry, _layoutConfig);
        // Stage 5: LayoutProposer facade is a thin delegate over the
        // existing partial; FocusService now takes IManagerRequestSender
        // + ILayoutProposer directly (retiring 4 bridge members).
        _layoutProposer = new Aqueous.Features.Layout.LayoutProposer(this);
        _focusService = new Aqueous.Features.Focus.FocusService(
            _windowRegistry, _outputRegistry, _seatRegistry,
            this, _managerRequestSender, _layoutProposer);
        // Stage 5: TagService no longer needs the ITagServiceCollaborators
        // bridge (deleted); ScheduleManage routed through IManagerRequestSender.
        _tagController = new TagService(
            _windowRegistry, _outputRegistry, _focusService, _managerRequestSender);
        _scratchpadRegistry = new ScratchpadRegistry();
        _stateHost = new RiverWindowStateHost(this);
        _windowState = new WindowStateController(
            _stateHost, _scratchpadRegistry);
        _startupExec = new StartupExecRunner(_stateHost, _layoutConfig.Exec);

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
        => TryStart(serviceProvider: null, cancellationToken);

    /// <summary>
    /// DI-aware overload. When <paramref name="serviceProvider"/> is
    /// non-null, <see cref="IWaylandConnection"/> and the three
    /// <c>I*Registry</c> seams are resolved from it; otherwise the
    /// legacy field-initialised defaults are used.
    /// </summary>
    public static Result<RiverWindowManagerClient> TryStart(
        IServiceProvider? serviceProvider,
        CancellationToken cancellationToken = default)
    {
        if (Environment.GetEnvironmentVariable("AQUEOUS_RIVER_WM") != "1")
        {
            return Result<RiverWindowManagerClient>.Fail(
                "AQUEOUS_RIVER_WM is not set to 1; refusing to attach as a window manager");
        }

        try
        {
            var c = serviceProvider is null
                ? new RiverWindowManagerClient()
                : new RiverWindowManagerClient(
                    (IWaylandConnection?)serviceProvider.GetService(typeof(IWaylandConnection)) ?? new WaylandConnection(),
                    (IWindowRegistry?)serviceProvider.GetService(typeof(IWindowRegistry)) ?? new WindowRegistry(),
                    (IOutputRegistry?)serviceProvider.GetService(typeof(IOutputRegistry)) ?? new OutputRegistry(),
                    (ISeatRegistry?)serviceProvider.GetService(typeof(ISeatRegistry)) ?? new SeatRegistry(),
                    (IEventPump?)serviceProvider.GetService(typeof(IEventPump)));
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

        // Stage 0: record the registry proxy → interface mapping. The
        // RegistryBinder owns the proxy; we read it back here purely to
        // populate _proxyInterface for the eventual interface-name based
        // dispatch in Stage 8.
        TrackProxyInterface(_registry.Handle, "wl_registry");

        _registry.Discovered += OnGlobalDiscovered;

        // Flush globals; then a second roundtrip so any events the
        // compositor sends immediately on bind (for an existing window
        // list) are delivered before we return.
        _connection.Roundtrip();
        _connection.Roundtrip();

        if (_manager == IntPtr.Zero)
        {
            return Result.Fail(
                "river_window_manager_v1 global was not advertised — is RiverDelta running with WM support?");
        }

        // Phase B1f: with the WM global bound and globals advertised, fire
        // the [[exec]] on_startup / when=always entries from wm.toml. This
        // runs synchronously on the connect thread, but each command is
        // detached via setsid so it returns immediately.
        try
        {
            _startupExec.OnStartup();
        }
        catch (Exception ex)
        {
            Log($"startup exec failed: {ex.Message}");
        }

        return Result.Ok;
    }

    private void StartPump(CancellationToken cancellationToken = default) =>
        _pump.Start(cancellationToken);

    /// <summary>
    /// Join timeout applied to <see cref="IEventPump.Stop"/> during
    /// <see cref="Dispose"/>. Long enough to let an in-flight
    /// <c>wl_display_dispatch</c> return after we cancel; short enough
    /// that a wedged libwayland never blocks shutdown indefinitely.
    /// </summary>
    private static readonly TimeSpan PumpJoinTimeout = TimeSpan.FromSeconds(2);

    public void Dispose()
    {
        // river_window_manager_v1::stop (opcode 0) is intentionally NOT
        // sent here: it is not a destructor — we'd still have to wait
        // for the `finished` event and then call destroy. For the
        // skeleton we just disconnect the display; River treats a
        // disconnected WM the same way as a stopped one and cleans up.
        try
        {
            // Critical ordering: stop the pump first so it is no
            // longer touching the wl_display, then dispose the
            // connection. Disposing the display while the pump is
            // blocked inside wl_display_dispatch is undefined
            // behaviour in libwayland.
            _pump.Stop(PumpJoinTimeout);
            _connection.Dispose();

            // Step 10 (sub-step 7): clear the three registries after the
            // pump is stopped so no late event handler observes a
            // half-torn dictionary, and so shutdown does not emit a
            // Removed storm to any subscribers.
            _windowRegistry.Clear();
            _outputRegistry.Clear();
            _seatRegistry.Clear();
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
                TrackProxyInterface(_manager, "river_window_manager_v1");
                _managerRequestSender.Init(_manager, _display);
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
            TrackProxyInterface(_layerShell, "river_layer_shell_v1");
            Log("bound river_layer_shell_v1");
        }
        else if (global.Interface == "river_xkb_bindings_v1")
        {
            uint xkbVersion = Math.Min(global.Version, 2u);
            _xkbBindings = _registry.Bind(global.Name, WlInterfaces.RiverXkbBindings, xkbVersion);
            _xkbBindingsVersion = xkbVersion;
            TrackProxyInterface(_xkbBindings, "river_xkb_bindings_v1");
            Log($"bound river_xkb_bindings_v1 (version {xkbVersion})");
        }
        else if (global.Interface == "wl_shm" && _wlShm == IntPtr.Zero)
        {
            _wlShm = _registry.Bind(global.Name, WlInterfaces.WlShm, 1);
            TrackProxyInterface(_wlShm, "wl_shm");
            Log("bound wl_shm");
            TryActivateScreencopy();
        }
        else if (global.Interface == "wl_output")
        {
            // Lazy-bind path: only remember the global. We bind a real
            // wl_output proxy on demand from CaptureOutputAsync and
            // destroy it immediately after capture. This avoids
            // surfacing the wl_output event stream on the WM's display
            // at all, which is what previously stalled toplevel
            // delivery and prevented windows from opening.
            _wlOutputGlobals[global.Name] = global;
        }
        else if (global.Interface == "zwlr_screencopy_manager_v1" && _screencopyManager == IntPtr.Zero)
        {
            _screencopyVersion = Math.Min(global.Version, 3u);
            _screencopyManager = _registry.Bind(
                global.Name, WlInterfaces.ZwlrScreencopyManager, _screencopyVersion);
            TrackProxyInterface(_screencopyManager, "zwlr_screencopy_manager_v1");
            Log($"bound zwlr_screencopy_manager_v1 (version {_screencopyVersion})");
            TryActivateScreencopy();
        }
    }

    /// <summary>
    /// Brings up <see cref="_screencopy"/> once both <c>wl_shm</c> and
    /// <c>zwlr_screencopy_manager_v1</c> have been bound. Order of registry
    /// events is not guaranteed, so this is called from each binding site.
    /// </summary>
    private void TryActivateScreencopy()
    {
        if (_screencopy != null || _screencopyManager == IntPtr.Zero || _wlShm == IntPtr.Zero)
        {
            return;
        }

        IntPtr dispatcher = (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch;
        _screencopy = new WlrScreencopyClient(
            _screencopyManager,
            _screencopyVersion,
            _wlShm,
            GCHandle.ToIntPtr(_selfHandle),
            dispatcher);
        Log("screencopy ready (wl_shm + zwlr_screencopy_manager_v1)");
    }

    /// <summary>
    /// Captures a full frame for the first known <c>wl_output</c>. Returns
    /// <c>null</c> if screencopy is unavailable. Intended for diagnostic /
    /// thumbnail consumers within the WM process; portal apps speak to
    /// RiverDelta directly.
    /// </summary>
    /// <param name="overlayCursor">Whether to composite the cursor.</param>
    public System.Threading.Tasks.Task<ScreencopyResult>? CaptureFirstOutputAsync(bool overlayCursor = false)
    {
        if (_screencopy == null)
        {
            return null;
        }

        RegistryGlobal? pick = null;
        foreach (var kv in _wlOutputGlobals)
        {
            pick = kv.Value;
            break;
        }

        if (pick is null)
        {
            return null;
        }

        // Bind a real wl_output proxy *just* for this capture. Version 1
        // is sufficient — capture_output only needs the object identity.
        // We destroy it after the frame completes so the wl_output event
        // stream never lingers on the WM's display.
        IntPtr output = _registry.Bind(pick.Value.Name, WlInterfaces.WlOutput, 1);
        if (output == IntPtr.Zero)
        {
            return null;
        }

        var task = _screencopy.CaptureOutputAsync(output, overlayCursor);
        // Destroy the proxy as soon as the capture finishes (success or
        // failure). The screencopy frame holds its own ref on the
        // wl_output for the duration of the capture, so an early destroy
        // on this side is safe.
        IntPtr captured = output;
        return task.ContinueWith(static (t, state) =>
        {
            WaylandInterop.wl_proxy_destroy((IntPtr)state!);
            return t.GetAwaiter().GetResult();
        }, captured, System.Threading.Tasks.TaskScheduler.Default);
    }
}
