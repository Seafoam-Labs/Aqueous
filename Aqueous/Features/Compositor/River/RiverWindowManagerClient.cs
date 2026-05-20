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
    //
    // PR 9.12 §2.13: the real sink is now Aqueous.Diagnostics.RiverLog.
    // The Log property below is a thin forwarder kept for source
    // compatibility with the ~28 existing call sites that still write
    // RiverWindowManagerClient.Log("…"). New code should call
    // RiverLog.Write directly so the final deletion of this god class
    // does not require a per-call-site sweep. Assigning the setter
    // re-points the underlying RiverLog.Sink (preserves the prior
    // test-injection contract).

    /// <summary>
    /// Forwarder to <see cref="Aqueous.Diagnostics.RiverLog"/>. Reads
    /// return the active <see cref="Aqueous.Diagnostics.RiverLog.Sink"/>;
    /// writes replace it. Behaviour byte-for-byte equivalent to the
    /// prior in-class implementation.
    /// </summary>
    public static Action<string> Log
    {
        get => Aqueous.Diagnostics.RiverLog.Sink;
        set => Aqueous.Diagnostics.RiverLog.Sink = value ?? throw new ArgumentNullException(nameof(value));
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

    // Pointer position at drag-start. Combined with op_delta's cumulative
    // (dx, dy) this lets us reconstruct the live cursor position during a
    // drag — river does NOT emit pointer_position while a drag is active.
    // Seeded at every drag-start site (PointerMove/Resize requested + Super
    // pointer-binding pressed); read by OpDelta to refresh _seatPointerPos.
    private int _dragStartPointerX;
    private int _dragStartPointerY;

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
    /// <summary>PR 9.12 §2.8: top-level dispatch seam for wl_registry globals.</summary>
    private readonly Aqueous.Features.Compositor.River.Connection.RegistryGlobalBinder _registryGlobalBinder;
    // PR 9.12 §2.10: top-level RiverEventDispatcher seam. Currently
    // not on the native callback path (NativeCallbackEntry still
    // round-trips through _selfHandle → this client); §2.13 repins
    // the GCHandle to a NativeCallbackContext wrapping this dispatcher.
    private readonly Aqueous.Features.Compositor.River.Dispatch.RiverEventDispatcher _riverEventDispatcher;
    /// <summary>PR 9.12 §2.8 migration accessor.</summary>
    internal Aqueous.Features.Compositor.River.Connection.RegistryGlobalBinder RegistryGlobalBinder => _registryGlobalBinder;
    /// <summary>PR 9.12 §2.10 migration accessor for the lifted event dispatcher seam.</summary>
    internal Aqueous.Features.Compositor.River.Dispatch.RiverEventDispatcher RiverEventDispatcher => _riverEventDispatcher;

    /// <summary>
    /// PR 9.12 §2.1: dedicated singleton that mirrors the bind-site
    /// proxy pointers. Populated alongside the legacy private fields
    /// below until every consumer takes <see cref="WaylandBindSiteState"/>
    /// directly via ctor injection. Exposed as <see cref="BindSiteState"/>
    /// for the gradual migration.
    /// </summary>
    private readonly Aqueous.Features.Compositor.River.Connection.WaylandBindSiteState _bindSiteState;

    /// <summary>PR 9.12 §2.1 migration accessor.</summary>
    internal Aqueous.Features.Compositor.River.Connection.WaylandBindSiteState BindSiteState => _bindSiteState;

    /// <summary>PR 9.12 §2.3 migration accessor.</summary>
    internal Aqueous.Features.State.OutputFullscreenMap OutputFullscreen => _outputFullscreen;

    /// <summary>PR 9.12 §2.4 migration accessor.</summary>
    internal Aqueous.Features.State.WindowStateStore WindowStates => _windowStates;

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
    // Stage 6 Part 2: WlrScreencopyClient ownership moved to ScreencopyService.
    private readonly Aqueous.Features.Screencopy.IScreencopyService _screencopyService =
        new Aqueous.Features.Screencopy.ScreencopyService();
    private readonly ConcurrentDictionary<uint, RegistryGlobal> _wlOutputGlobals = new();

    // --- key bindings -------------------------------------------------

    private readonly Dictionary<IntPtr, KeyBindingAction> _keyBindings = new();

    // Pointer-binding per-seat dedupe (consumed by the Manager event
    // handler partial when it issues get_pointer_binding requests).
    // Lifted out of the deleted KeyBindingRegistrar.cs partial in
    // PR 9.12 §2.13 because it's pointer-binding state, not key-binding
    // state, and stays on the god class until the Manager handler
    // ctor is migrated off `this`.
    private readonly HashSet<IntPtr> _seatsWithPointerBindings = new();

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
        // PR 9.12 §2.13 bind-site migration: writes go to the singleton
        // (single source of truth); the legacy per-instance map is kept
        // mirrored for in-flight callers that still read via _proxyInterface.
        _bindSiteState.TrackProxyInterface(proxy, interfaceName);
        _proxyInterface.Track(proxy, interfaceName);
    }

    /// <summary>Test/diagnostic accessor: number of proxies currently tracked.</summary>
    internal int TrackedProxyCount => _bindSiteState.TrackedProxyCount;

    /// <summary>Test/diagnostic accessor: lookup the recorded interface name.</summary>
    /// <remarks>
    /// PR 9.12 §2.13 bind-site migration: reads now go through the
    /// <see cref="WaylandBindSiteState"/> singleton; the per-instance
    /// <c>_proxyInterface</c> map is retained only as a write-through mirror
    /// and retires together with the god class in the final demolition step.
    /// </remarks>
    internal string? TryGetProxyInterface(IntPtr proxy) => _bindSiteState.TryGetProxyInterface(proxy);

    // For KeyBindingAction.Custom — chord proxy → free-form action verb.
    private readonly Dictionary<IntPtr, string> _customBindingActions = new();


    private IntPtr _primarySeat;

    // PR 9.12 §2.2: _focusedWindow's storage now lives on
    // FocusedWindowTracker (DI singleton). The property below preserves
    // the field-style name so the ~13 read sites and ~3 write sites
    // scattered across handlers + Focus/Layout partials don't churn
    // until each one ctor-injects the tracker directly.
    private readonly Aqueous.Features.Focus.FocusedWindowTracker _focusedWindowTracker;
    private IntPtr _focusedWindow
    {
        get => _focusedWindowTracker.Current;
        set => _focusedWindowTracker.Current = value;
    }
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
    // PR 9.12 §2.13: GCHandle is now pinned via NativeCallbackContext rather
    // than directly on `this`. `_selfHandle` is rehydrated from the context's
    // IntPtr so all existing `GCHandle.ToIntPtr(_selfHandle)` call sites
    // continue to round-trip to the context (whose `Client` back-reference
    // exposes this instance). The context owns the actual GCHandle.Alloc.
    private GCHandle _selfHandle;
    private Aqueous.Features.Compositor.River.Dispatch.NativeCallbackContext? _callbackContext;

    // Stage 5: Wayland-send seam. Owned by this class for lifetime
    // management; Init() is called from OnGlobalDiscovered once the
    // river_window_manager_v1 proxy has been bound.
    // Stage 6 Part 1: facade over the SnapZones partial.
    private readonly Aqueous.Features.SnapZones.ISnapZoneService _snapZoneService;

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
    // PR 9.12 §2.4: backed by the DI-resolved WindowStateStore singleton;
    // the field name is preserved so all existing consumers in the partial
    // files (WindowEventHandler, ManagerEventHandler, LayoutProposer,
    // WindowStateHostAccessors) keep compiling unchanged.
    private readonly Aqueous.Features.State.WindowStateStore _windowStates;

    // Per-output single-FS slot (single-fullscreen-per-output rule).
    // PR 9.12 §2.3: backed by the DI-resolved OutputFullscreenMap singleton;
    // the field name is preserved so all existing consumers in the partial
    // files (LayoutProposer, WindowEventHandler, WindowStateHostAccessors)
    // keep compiling unchanged.
    private readonly Aqueous.Features.State.OutputFullscreenMap _outputFullscreen;

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

    /// <summary>
    /// PR 9.12 §2.13 increment: exposed so <see cref="RiverCompositorHost"/>
    /// can invoke <c>OnStartup</c> after <see cref="Connect"/> returns,
    /// moving one more lifecycle responsibility out of the god class.
    /// </summary>
    internal StartupExecRunner StartupExec => _startupExec;
    private readonly Aqueous.Features.State.WindowStateHost _stateHost;
    // Stage 8 PR 8.1: managed dispatch seam. The native [UnmanagedCallersOnly]
    // callback in ProxyDispatcher routes per-interface branches through this
    // dispatcher as each handler is extracted out of the god class. PR 8.1
    // registers only LayerShellEventHandler; PRs 8.2-8.7 add the rest.
    private readonly Aqueous.Features.Compositor.River.Dispatch.IEventDispatcher _eventDispatcher;

    // Stage 9 PR 9.1: typed handler fields so each can be exposed via DI
    // factory registration. The instances stored here are the same ones
    // composing _eventDispatcher's table; we keep both references so the
    // dispatcher routing remains byte-for-byte equivalent.
    private readonly Aqueous.Features.Compositor.River.Dispatch.EventHandlers.LayerShellEventHandler _layerShellHandler;
    private readonly Aqueous.Features.Compositor.River.Dispatch.EventHandlers.OutputEventHandler _outputHandler;
    private readonly Aqueous.Features.Compositor.River.Dispatch.EventHandlers.SeatEventHandler _seatHandler;
    private readonly Aqueous.Features.Compositor.River.Dispatch.EventHandlers.WindowEventHandler _windowHandler;
    private readonly Aqueous.Features.Compositor.River.Dispatch.EventHandlers.ManagerEventHandler _managerHandler;
    private readonly Aqueous.Features.Compositor.River.Dispatch.EventHandlers.SuperKeyBindingEventHandler _superKeyBindingHandler;
    private readonly Aqueous.Features.Compositor.River.Dispatch.EventHandlers.DragPointerBindingEventHandler _dragPointerBindingHandler;
    private readonly Aqueous.Features.Compositor.River.Dispatch.EventHandlers.RegistryEventHandler _registryHandler;
    private readonly Aqueous.Features.Compositor.River.Dispatch.EventHandlers.KeyBindingEventHandler _keyBindingHandler;
    private readonly Aqueous.Features.Compositor.River.Dispatch.EventHandlers.ScreencopyFrameHandler _screencopyFrameHandler;

    // Stage 9 PR 9.1: DI accessors. Every service constructed inline in
    // the ctor (Stages 2–8 collaborator-bridge pattern) is exposed here
    // so Program.cs can register each one as a DI singleton via factory
    // lambda — closing the "fix DI" tech-debt the decomposition has been
    // tracking. These properties will be deleted in PR 9.12 once each
    // service is registered directly (no longer via the god class).
    internal Aqueous.Features.Compositor.River.Dispatch.IEventDispatcher EventDispatcher => _eventDispatcher;
    // PR 9.3 Stage 9: expose RegistryBinder so it can be DI-registered as a singleton.
    internal Aqueous.Features.Compositor.River.Connection.RegistryBinder RegistryBinder => _registry;
    internal Aqueous.Features.Focus.IFocusService FocusService => _focusService;
    internal Aqueous.Features.Tags.ITagService TagService => _tagController;
    internal Aqueous.Features.Layout.IManagerRequestSender ManagerRequestSender => _managerRequestSender;
    internal Aqueous.Features.Layout.ILayoutProposer LayoutProposer => _layoutProposer;
    internal Aqueous.Features.SnapZones.ISnapZoneService SnapZoneService => _snapZoneService;
    internal Aqueous.Features.Screencopy.IScreencopyService ScreencopyService => _screencopyService;
    // PR 9.12 §2.6: bindings-trio service fields lifted here from the
    // retired BindingsAccessors.cs partial. Field names are pinned by
    // Stage7Tests.
    internal Aqueous.Features.Bindings.IKeyBindingRegistrar _keyBindingRegistrar = null!;
    internal Aqueous.Features.Bindings.IKeyBindingRouter _keyBindingRouter = null!;
    internal Aqueous.Features.Bindings.ICustomActionRunner _customActionRunner = null!;
    internal Aqueous.Features.Bindings.IProcessLauncher _processLauncher = null!;
    internal Aqueous.Features.Bindings.IProcessLauncher ProcessLauncher => _processLauncher;
    internal Aqueous.Features.Bindings.ICustomActionRunner CustomActionRunner => _customActionRunner;
    internal Aqueous.Features.Bindings.IKeyBindingRegistrar KeyBindingRegistrar => _keyBindingRegistrar;
    internal Aqueous.Features.Bindings.IKeyBindingRouter KeyBindingRouter => _keyBindingRouter;

    // PR 9.12 §2.13: pass-through forwarders for the lifted top-level
    // KeyBindingRegistrar. The partial that previously owned the bodies
    // is deleted; both forwarders now delegate to _keyBindingRegistrar.
    // Retained as internal methods because Stage9Pr99Tests pins their
    // existence; retire together with the god class in the final
    // demolition step.
    internal void RegisterAllBindingsForwarding(IntPtr seatProxy)
        => _keyBindingRegistrar.RegisterAllBindings(seatProxy);

    internal bool IsBindingRegisteredForwarding(IntPtr bindingProxy)
        => _keyBindings.ContainsKey(bindingProxy);

    // PR 9.12 §2.13 — internal accessors for the lifted KeyBindingRegistrar.
    // Retire together with the god class.
    internal IntPtr XkbBindings => _xkbBindings;
    internal uint XkbBindingsVersion => _xkbBindingsVersion;
    internal Dictionary<IntPtr, KeyBindingAction> KeyBindings => _keyBindings;
    internal Dictionary<IntPtr, string> CustomBindingActions => _customBindingActions;
    internal IntPtr SelfHandlePtr => GCHandle.ToIntPtr(_selfHandle);
    internal LayoutConfig LayoutConfigForRegistrar => _layoutConfig;

    // PR 9.12 §2.13 — internal accessors for the lifted top-level
    // LayoutProposer. Retire together with the god class.
    internal IWindowRegistry WindowRegistry => _windowRegistry;
    internal IOutputRegistry OutputRegistry => _outputRegistry;
    internal IntPtr FocusedWindowHandle => _focusedWindow;
    internal HashSet<IntPtr> PrevFullscreenHandles => _prevFullscreenHandles;
    internal LayoutController LayoutController => _layoutController;

    // PR 9.12 §2.13 — god-class forwarders for the lifted top-level
    // LayoutProposer. Several event-handler partials still call these
    // methods unqualified via `this`; the forwarders delegate to the
    // lifted service. Retire together with the god class.
    internal void ProposeForArea(IntPtr output, string? outputName, Rect usableArea)
        => _layoutProposer.ProposeForArea(output, outputName, usableArea);
    internal bool IsFloatLayoutActive() => _layoutProposer.IsFloatLayoutActive();
    internal bool IsFloatLayoutActive(IntPtr output) => _layoutProposer.IsFloatLayoutActive(output);
    internal IReadOnlyList<WindowEntryView> BuildSnapshotFor(IntPtr output)
        => _layoutProposer.BuildSnapshotFor(output);
    internal string? ResolveOutputName(IntPtr output) => _layoutProposer.ResolveOutputName(output);

    internal Aqueous.Features.Compositor.River.Dispatch.EventHandlers.LayerShellEventHandler LayerShellHandler => _layerShellHandler;
    internal Aqueous.Features.Compositor.River.Dispatch.EventHandlers.OutputEventHandler OutputHandler => _outputHandler;
    internal Aqueous.Features.Compositor.River.Dispatch.EventHandlers.SeatEventHandler SeatHandler => _seatHandler;
    internal Aqueous.Features.Compositor.River.Dispatch.EventHandlers.WindowEventHandler WindowHandler => _windowHandler;
    internal Aqueous.Features.Compositor.River.Dispatch.EventHandlers.ManagerEventHandler ManagerHandler => _managerHandler;
    internal Aqueous.Features.Compositor.River.Dispatch.EventHandlers.SuperKeyBindingEventHandler SuperKeyBindingHandler => _superKeyBindingHandler;
    internal Aqueous.Features.Compositor.River.Dispatch.EventHandlers.DragPointerBindingEventHandler DragPointerBindingHandler => _dragPointerBindingHandler;
    internal Aqueous.Features.Compositor.River.Dispatch.EventHandlers.RegistryEventHandler RegistryHandler => _registryHandler;
    internal Aqueous.Features.Compositor.River.Dispatch.EventHandlers.KeyBindingEventHandler KeyBindingHandler => _keyBindingHandler;
    internal Aqueous.Features.Compositor.River.Dispatch.EventHandlers.ScreencopyFrameHandler ScreencopyFrameHandler => _screencopyFrameHandler;

    // PR 9.4 Stage 9: pass-through accessors that retire the
    // IKeyBindingHandlerCollaborators / ISuperKeyBindingHandlerCollaborators
    // bridges. The body of OnKeyBindingEvent / OnSuperKeyBindingEvent still
    // lives in the existing partials (they read god-class private dicts
    // and call private helpers — final lift is Stage 9 cleanup); routing
    // here keeps managed-handler behaviour byte-for-byte equivalent.
    internal unsafe void HandleKeyBindingEvent(IntPtr target, uint opcode, WlArgument* args)
        => ((Aqueous.Features.Bindings.KeyBindingRegistrar)_keyBindingRegistrar).HandleKeyBindingEvent(target, opcode, args);
    internal unsafe void HandleSuperKeyBindingEvent(uint opcode, WlArgument* args)
        => OnSuperKeyBindingEvent(opcode, args);
    // PR 9.5: retires IDragPointerBindingHandlerCollaborators bridge.
    internal unsafe void HandleDragPointerBindingEvent(IntPtr target, uint opcode, WlArgument* args)
        => OnDragPointerBindingEvent(target, opcode, args);
    // PR 9.7: retires IWindowHandlerCollaborators / IManagerHandlerCollaborators bridges.
    internal unsafe void HandleWindowEvent(IntPtr proxy, uint opcode, WlArgument* args)
        => OnWindowEvent(proxy, opcode, args);
    internal unsafe void HandleManagerEvent(uint opcode, WlArgument* args)
        => OnManagerEvent(opcode, args);

    // PR 9.8 Stage 9: pass-through accessors retiring the
    // IOutputHandlerCollaborators + ILayoutProposerCollaborators bridges.
    // Bodies still live in the existing partials; Stage 9 final cleanup
    // collapses the god class.
    internal IEnumerable<Aqueous.Features.State.WindowStateData> SnapshotWindowStates()
    {
        var snapshot = new List<Aqueous.Features.State.WindowStateData>(_windowStates.Count);
        foreach (var kv in _windowStates)
        {
            snapshot.Add(kv.Value);
        }
        return snapshot;
    }
    internal void OnOutputRemovedForwarding(
        Aqueous.Features.State.OutputProxy output,
        IList<Aqueous.Features.State.WindowStateData> windowsOnOutput)
        => _windowState.OnOutputRemoved(output, windowsOnOutput);
    internal void OutputFullscreenTryRemove(IntPtr output)
        => _outputFullscreen.TryRemove(output, out _);
    // PR 9.12 §2.9: LayoutFocusNeighbor surfaced directly on the god class so
    // the lifted LayoutProposer facade can call it without the "*Forwarding"
    // wrapper. The five other layout/focus forwarders (ProposeForArea,
    // IsFloatLayoutActive x2, BuildSnapshotFor, ResolveOutputName) retired —
    // those bodies live on the LayoutProposer partial and are now internal.
    internal IntPtr? LayoutFocusNeighbor(
        IntPtr output,
        string? outputName,
        IntPtr current,
        Aqueous.Features.Layout.FocusDirection dir,
        IReadOnlyList<Aqueous.Features.Layout.WindowEntryView> snapshot)
        => _layoutController.FocusNeighbor(output, outputName, current, dir, snapshot);

    private RiverWindowManagerClient()
        : this(
            new WaylandConnection(),
            new WindowRegistry(),
            new OutputRegistry(),
            new SeatRegistry(),
            pump: null)
    {
    }

    // PR 9.11: surfaced as internal so RiverCompositorHost / Program.cs
    // can construct the client from DI without going through TryStart
    // (which both opens the Wayland connection and starts the pump).
    internal RiverWindowManagerClient(
        IWaylandConnection connection,
        IWindowRegistry windowRegistry,
        IOutputRegistry outputRegistry,
        ISeatRegistry seatRegistry,
        IEventPump? pump)
        : this(connection, windowRegistry, outputRegistry, seatRegistry, pump,
               new Aqueous.Features.Compositor.River.Connection.WaylandBindSiteState(),
               new Aqueous.Features.Focus.FocusedWindowTracker(),
               new Aqueous.Features.State.OutputFullscreenMap(),
               new Aqueous.Features.State.WindowStateStore())
    {
    }

    // PR 9.12 §2.1/§2.2/§2.3/§2.4: ctor overload that accepts DI-supplied
    // WaylandBindSiteState + FocusedWindowTracker + OutputFullscreenMap +
    // WindowStateStore singletons. Earlier overloads delegate here with
    // fresh instances so existing callers (TryStart, tests) are unaffected.
    internal RiverWindowManagerClient(
        IWaylandConnection connection,
        IWindowRegistry windowRegistry,
        IOutputRegistry outputRegistry,
        ISeatRegistry seatRegistry,
        IEventPump? pump,
        Aqueous.Features.Compositor.River.Connection.WaylandBindSiteState bindSiteState,
        Aqueous.Features.Focus.FocusedWindowTracker focusedWindowTracker,
        Aqueous.Features.State.OutputFullscreenMap outputFullscreen,
        Aqueous.Features.State.WindowStateStore windowStates)
    {
        _bindSiteState = bindSiteState ?? throw new ArgumentNullException(nameof(bindSiteState));
        _focusedWindowTracker = focusedWindowTracker ?? throw new ArgumentNullException(nameof(focusedWindowTracker));
        _outputFullscreen = outputFullscreen ?? throw new ArgumentNullException(nameof(outputFullscreen));
        _windowStates = windowStates ?? throw new ArgumentNullException(nameof(windowStates));
        _registryGlobalBinder = new Aqueous.Features.Compositor.River.Connection.RegistryGlobalBinder(this);
        _riverEventDispatcher = new Aqueous.Features.Compositor.River.Dispatch.RiverEventDispatcher(this);
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
        // Stage 6 Part 1: SnapZoneService facade over the existing
        // partial; handlers depend on ISnapZoneService rather than
        // god-class privates. Literal drag-state lift in Stage 8.
        _snapZoneService = new Aqueous.Features.SnapZones.SnapZoneService(this);
        // Stage 7: bindings trio facade — IKeyBindingRegistrar /
        // IKeyBindingRouter / ICustomActionRunner all forward to the
        // existing god-class partials via IKeyBindingsCollaborators.
        // IProcessLauncher is a clean AOT-safe extraction with no
        // god-class coupling. Literal lift of the 671-line bindings
        // partials is deferred to Stage 7b/8 (see bridge XML-doc).
        _processLauncher = new Aqueous.Features.Bindings.ProcessLauncher();
        _scratchpadRegistry = new ScratchpadRegistry();
        // PR 9.12 §2.13: WindowStateHost 8-arg DI ctor cutover. The host no
        // longer references the god class; the eight fine-grained singletons
        // it consumed via the deleted WindowStateHostAccessors partial are
        // now injected directly.
        _stateHost = new Aqueous.Features.State.WindowStateHost(
            _windowRegistry,
            _outputRegistry,
            _windowStates,
            _outputFullscreen,
            _focusedWindowTracker,
            _focusService,
            _managerRequestSender,
            _layoutController);
        _windowState = new WindowStateController(
            _stateHost, _scratchpadRegistry);
        _keyBindingRegistrar = new Aqueous.Features.Bindings.KeyBindingRegistrar(this);
        // PR 9.12 §2.13: the routers no longer reference the god class at all.
        // The mutable LayoutConfig is owned by LayoutController; the default
        // config path is resolved through Aqueous.Features.Configuration.
        var viewport = new Aqueous.Features.Layout.ViewportInteractionService(
            _layoutController, _focusedWindowTracker, _windowRegistry, _layoutProposer, _managerRequestSender);
        var router = new Aqueous.Features.Bindings.KeyBindingRouter(
            _focusService, _layoutController, _tagController,
            _managerRequestSender, _windowState, viewport);
        _keyBindingRouter = router;
        _customActionRunner = new Aqueous.Features.Bindings.CustomActionRunner(
            router, _focusService, _windowState);
        _startupExec = new StartupExecRunner(_stateHost, _layoutConfig.Exec);

        // Push libinput config to the privileged sidecar (aqueous-inputd).
        // Best-effort: silently logs and proceeds if the daemon isn't up.
        // River 0.4 owns libinput but exposes no API to a WM client, so
        // pointer accel etc. can only be applied out-of-process. Mirrors
        // niri's "apply on startup + on config reload" model — the same
        // call lives in ReloadConfig (KeyBindingActionRouter).
        InputDaemonClient.Apply(_layoutConfig.Input);

        // Stage 9 PR 9.1: instantiate each handler into a typed field so it
        // can be exposed via DI factory registration (Program.cs). The
        // dispatcher table below references the same instances — routing
        // remains byte-for-byte equivalent to Stage 8.
        _layerShellHandler = new Aqueous.Features.Compositor.River.Dispatch.EventHandlers.LayerShellEventHandler(Log);
        _outputHandler = new Aqueous.Features.Compositor.River.Dispatch.EventHandlers.OutputEventHandler(
            _windowRegistry, _outputRegistry, this, Log);
        _seatHandler = new Aqueous.Features.Compositor.River.Dispatch.EventHandlers.SeatEventHandler(
            _seatRegistry, _windowRegistry,
            _seatHoveredWindow, _seatPointerPos,
            this, Log);
        _windowHandler = new Aqueous.Features.Compositor.River.Dispatch.EventHandlers.WindowEventHandler(
            _windowRegistry, this, Log);
        _managerHandler = new Aqueous.Features.Compositor.River.Dispatch.EventHandlers.ManagerEventHandler(this, Log);
        _superKeyBindingHandler = new Aqueous.Features.Compositor.River.Dispatch.EventHandlers.SuperKeyBindingEventHandler(this, Log);
        _dragPointerBindingHandler = new Aqueous.Features.Compositor.River.Dispatch.EventHandlers.DragPointerBindingEventHandler(this, Log);
        _registryHandler = new Aqueous.Features.Compositor.River.Dispatch.EventHandlers.RegistryEventHandler(_registry, Log);
        _keyBindingHandler = new Aqueous.Features.Compositor.River.Dispatch.EventHandlers.KeyBindingEventHandler(this, Log);
        _screencopyFrameHandler = new Aqueous.Features.Compositor.River.Dispatch.EventHandlers.ScreencopyFrameHandler(_screencopyService, Log);

        _eventDispatcher = new Aqueous.Features.Compositor.River.Dispatch.EventDispatcher(
            new Aqueous.Features.Compositor.River.Dispatch.IEventHandler[]
            {
                _layerShellHandler,
                _outputHandler,
                _seatHandler,
                _windowHandler,
                _managerHandler,
                _superKeyBindingHandler,
                _dragPointerBindingHandler,
                _registryHandler,
                _keyBindingHandler,
                _screencopyFrameHandler,
            });
    }

    // PR 9.12 §2.12: lifted to Aqueous.Features.Configuration.DefaultConfigPath.
    internal static string GetDefaultConfigPath()
        => Aqueous.Features.Configuration.DefaultConfigPath.Resolve();

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
        // PR 9.11: env-var gating lifted to RiverEnvironmentGuard so
        // RiverCompositorHost can short-circuit startup with the same
        // friendly error before DI builds the client.
        if (!RiverEnvironmentGuard.IsEnabled())
        {
            return Result<RiverWindowManagerClient>.Fail(RiverEnvironmentGuard.NotEnabledMessage);
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

            try { c._startupExec.OnStartup(); }
            catch (Exception ex) { Log($"startup exec failed: {ex.Message}"); }

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

    // PR 9.11: surfaced as internal so RiverCompositorHost.StartAsync can
    // drive Connect after DI construction. TryStart keeps the legacy
    // in-factory path working for tests that still call it directly.
    internal Result Connect()
    {
        var connectResult = _connection.Connect();
        if (!connectResult.IsOk)
        {
            Log("wl_display_connect failed: " + connectResult.Error);
            return connectResult;
        }

        WlInterfaces.EnsureBuilt();

        // PR 9.12 §2.13: allocate a NativeCallbackContext (which performs the
        // actual GCHandle.Alloc internally) and rehydrate _selfHandle from
        // its IntPtr so all call sites that still read GCHandle.ToIntPtr(_selfHandle)
        // continue to round-trip to the context. NativeCallbackEntry.Dispatch
        // resolves the client through the context's `Client` back-reference.
        _callbackContext = new Aqueous.Features.Compositor.River.Dispatch.NativeCallbackContext(
            _riverEventDispatcher, this);
        _selfHandle = GCHandle.FromIntPtr(_callbackContext.Handle);
        IntPtr dispatcher = (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch.NativeCallbackEntry.Dispatch;

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

        _registry.Discovered += _registryGlobalBinder.Bind;

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

        // PR 9.12 §2.13 increment: startup-exec invocation lifted to
        // RiverCompositorHost.StartAsync (runs after Connect returns ok).
        // The TryStart legacy path still drives it inline below.
        return Result.Ok;
    }

    // PR 9.11: surfaced as internal so RiverCompositorHost.StartAsync can
    // drive the pump after Connect; TryStart still uses it internally.
    internal void StartPump(CancellationToken cancellationToken = default) =>
        _pump.Start(cancellationToken);

    /// <summary>
    /// Version of the bound <c>river_window_manager_v1</c> proxy, set in
    /// <see cref="OnGlobalDiscovered"/>. Exposed (PR 9.11) so the host
    /// can log it after driving Connect itself.
    /// </summary>
    internal uint ManagerVersion => _managerVersion;

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
            // PR 9.12 §2.13: dispose the callback context (which frees the
            // pinned GCHandle); _selfHandle is just an alias for the same
            // handle so we don't need to Free it separately. Fallback path
            // (legacy direct-pin) retained for safety: if for any reason the
            // context wasn't constructed but the handle was, free it.
            if (_callbackContext is { } ctx)
            {
                ctx.Dispose();
                _callbackContext = null;
            }
            else if (_selfHandle.IsAllocated)
            {
                _selfHandle.Free();
            }
        }
    }


    // --- registry ------------------------------------------------------

    internal void HandleRegistryGlobal(RegistryGlobal global)
    {
        // The set of interfaces this client cares about. Anything else
        // advertised by the compositor is intentionally ignored.
        if (global.Interface == "river_window_manager_v1" && _manager == IntPtr.Zero)
        {
            _managerVersion = Math.Min(global.Version, 4u);
            _manager = _registry.Bind(global.Name, WlInterfaces.RiverWindowManager, _managerVersion);
            _bindSiteState.Manager = _manager;
            if (_manager != IntPtr.Zero)
            {
                WaylandInterop.wl_proxy_add_dispatcher(
                    _manager,
                    (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch.NativeCallbackEntry.Dispatch,
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
            _bindSiteState.LayerShell = _layerShell;
            WaylandInterop.wl_proxy_add_dispatcher(
                _layerShell,
                (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch.NativeCallbackEntry.Dispatch,
                GCHandle.ToIntPtr(_selfHandle),
                IntPtr.Zero);
            TrackProxyInterface(_layerShell, "river_layer_shell_v1");
            Log("bound river_layer_shell_v1");
        }
        else if (global.Interface == "river_xkb_bindings_v1")
        {
            uint xkbVersion = Math.Min(global.Version, 2u);
            _xkbBindings = _registry.Bind(global.Name, WlInterfaces.RiverXkbBindings, xkbVersion);
            _bindSiteState.XkbBindings = _xkbBindings;
            _xkbBindingsVersion = xkbVersion;
            TrackProxyInterface(_xkbBindings, "river_xkb_bindings_v1");
            Log($"bound river_xkb_bindings_v1 (version {xkbVersion})");
        }
        else if (global.Interface == "wl_shm" && _wlShm == IntPtr.Zero)
        {
            _wlShm = _registry.Bind(global.Name, WlInterfaces.WlShm, 1);
            _bindSiteState.WlShm = _wlShm;
            TrackProxyInterface(_wlShm, "wl_shm");
            Log("bound wl_shm");
            _screencopyService.ActivateIfReady(
                _bindSiteState,
                _screencopyVersion,
                GCHandle.ToIntPtr(_selfHandle),
                (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch.NativeCallbackEntry.Dispatch,
                Log);
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
            _bindSiteState.ScreencopyManager = _screencopyManager;
            TrackProxyInterface(_screencopyManager, "zwlr_screencopy_manager_v1");
            Log($"bound zwlr_screencopy_manager_v1 (version {_screencopyVersion})");
            _screencopyService.ActivateIfReady(
                _bindSiteState,
                _screencopyVersion,
                GCHandle.ToIntPtr(_selfHandle),
                (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch.NativeCallbackEntry.Dispatch,
                Log);
        }
    }

    // PR 9.12 §2.13 increment: TryActivateScreencopy lifted onto
    // IScreencopyService.ActivateIfReady (consumed directly by HandleRegistryGlobal).

    /// <summary>
    /// Captures a full frame for the first known <c>wl_output</c>. Returns
    /// <c>null</c> if screencopy is unavailable. Intended for diagnostic /
    /// thumbnail consumers within the WM process; portal apps speak to
    /// RiverDelta directly.
    /// </summary>
    /// <param name="overlayCursor">Whether to composite the cursor.</param>
    public System.Threading.Tasks.Task<ScreencopyResult>? CaptureFirstOutputAsync(bool overlayCursor = false)
        => _screencopyService.CaptureFirstOutputAsync(
            _wlOutputGlobals.Values,
            name => _registry.Bind(name, WlInterfaces.WlOutput, 1),
            WaylandInterop.wl_proxy_destroy,
            overlayCursor);
}
