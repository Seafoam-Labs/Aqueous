using System;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Diagnostics;
using Aqueous.Features.Bindings;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Focus;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Owns the six seat-bridge methods. Consumed by <c>SeatEventHandler.Managed.cs</c> in place of
/// the prior <c>_river.*</c> calls.
/// <para>
/// the last <c>RiverWindowManagerClient</c> coupling (drag-rect / drag-edges / drag-finished
/// forwarders) is gone — that state now lives on <see cref="DragStateStore"/>, which the service
/// consumes directly. All dependencies are now fine-grained DI singletons (<see
/// cref="DragStateStore"/>, <see cref="IWindowRegistry"/>, <see cref="IFocusService"/>, <see
/// cref="ILayoutProposer"/>, <see cref="IManagerRequestSender"/>,
/// <see cref="LayoutController"/>).
/// </para>
/// <para>
/// Pump-thread only.
/// </para>
/// </summary>
internal sealed unsafe class SeatInteractionService
{
    private readonly DragStateStore _dragState;
    private readonly IWindowRegistry _windowRegistry;
    private readonly IFocusService _focusService;
    private readonly ILayoutProposer _layoutProposer;
    private readonly IManagerRequestSender _managerRequestSender;
    private readonly LayoutController _layoutController;
    private readonly WaylandBindSiteState _bindSiteState;
    private readonly KeyBindingsRegistry _keyBindingsRegistry;
    private readonly IShellSurfaceRegistry _shellSurfaceRegistry;
    private readonly ILayerShellTeardownService _layerShellTeardown;
    private readonly object _pendingMouseFocusLock = new();
    private CancellationTokenSource? _pendingMouseFocus;

    public SeatInteractionService(
        DragStateStore dragState,
        IWindowRegistry windowRegistry,
        IFocusService focusService,
        ILayoutProposer layoutProposer,
        IManagerRequestSender managerRequestSender,
        LayoutController layoutController,
        WaylandBindSiteState bindSiteState,
        KeyBindingsRegistry keyBindingsRegistry,
        IShellSurfaceRegistry shellSurfaceRegistry,
        ILayerShellTeardownService layerShellTeardown)
    {
        _dragState = dragState ?? throw new ArgumentNullException(nameof(dragState));
        _windowRegistry = windowRegistry ?? throw new ArgumentNullException(nameof(windowRegistry));
        _focusService = focusService ?? throw new ArgumentNullException(nameof(focusService));
        _layoutProposer = layoutProposer ?? throw new ArgumentNullException(nameof(layoutProposer));
        _managerRequestSender = managerRequestSender ?? throw new ArgumentNullException(nameof(managerRequestSender));
        _layoutController = layoutController ?? throw new ArgumentNullException(nameof(layoutController));
        _bindSiteState = bindSiteState ?? throw new ArgumentNullException(nameof(bindSiteState));
        _keyBindingsRegistry = keyBindingsRegistry ?? throw new ArgumentNullException(nameof(keyBindingsRegistry));
        _shellSurfaceRegistry = shellSurfaceRegistry ?? throw new ArgumentNullException(nameof(shellSurfaceRegistry));
        _layerShellTeardown = layerShellTeardown ?? throw new ArgumentNullException(nameof(layerShellTeardown));
    }

    /// <summary>
    /// Handle <c>river_seat_v1::removed</c>: destroy the per-seat <c>river_layer_shell_seat_v1</c>
    /// sub-object (now inert) and clear its layer-shell focus state.
    /// </summary>
    public void HandleSeatRemoved(IntPtr seat)
    {
        RiverLog.Write("BRIDGE HandleSeatRemoved seat=0x" + seat.ToString("x"));
        CancelPendingMouseFocus();
        _layerShellTeardown.TeardownSeat(seat);
    }

    public void CachePointerPosition(IntPtr seat, int x, int y)
    {
        // River_window_management_v1::pointer_position declares its args as type="int" in the protocol
        // XML — global logical coordinates already in pixel space, NOT wl_fixed. Cache as-is.
        _dragState.SeatPointerPos[seat] = (x, y);
    }

    public void HandleWindowInteraction(IntPtr window, IntPtr seat)
    {
        RiverLog.Write("BRIDGE HandleWindowInteraction window=0x" + window.ToString("x") + " seat=0x" + seat.ToString("x"));
        CancelPendingMouseFocus();
        _focusService.SetFocusedWindow(window, seat);
    }

    public void HandleShellSurfaceInteraction(IntPtr shellSurface, IntPtr seat)
    {
        RiverLog.Write("BRIDGE HandleShellSurfaceInteraction ss=0x" + shellSurface.ToString("x") + " seat=0x" + seat.ToString("x"));
        CancelPendingMouseFocus();
        // First sight of this river_shell_surface_v1 proxy: install the event dispatcher and track
        // its interface so its events (notably destroyed, opcode 0) route to ShellSurfaceEventHandler.
        // Aqueous never calls get_shell_surface, so the proxy only ever surfaces here as an object
        // argument and this is the only place it can be wired up. Idempotent: skip if already tracked.
        EnsureShellSurfaceTracked(shellSurface);
        _shellSurfaceRegistry.Add(shellSurface);
        _focusService.SetFocusedShellSurface(shellSurface, seat);
    }

    private void EnsureShellSurfaceTracked(IntPtr shellSurface)
    {
        if (shellSurface == IntPtr.Zero || _bindSiteState.TryGetProxyInterface(shellSurface) != null)
        {
            return;
        }

        WaylandInterop.wl_proxy_add_dispatcher(
            shellSurface,
            (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)
            &Aqueous.Features.Compositor.River.Dispatch.NativeCallbackEntry.Dispatch,
            _keyBindingsRegistry.SelfHandlePtr,
            IntPtr.Zero);
        _bindSiteState.TrackProxyInterface(shellSurface, "river_shell_surface_v1");
        RiverLog.Write($"+ shell surface 0x{shellSurface.ToString("x")}");
    }

    /// <summary>
    /// Handle <c>river_shell_surface_v1::destroyed</c>: the compositor has reported the shell-surface
    /// object is no longer valid server-side. Drop any pending focus that targets it (so the manage
    /// cycle can never marshal <c>focus_shell_surface</c> on the freed proxy — the "segfault at 2c"
    /// crash), stop tracking it, and destroy the proxy per protocol.
    /// </summary>
    public void HandleShellSurfaceDestroyed(IntPtr shellSurface)
    {
        RiverLog.Write("BRIDGE HandleShellSurfaceDestroyed ss=0x" + shellSurface.ToString("x"));
        CancelPendingMouseFocus();
        if (shellSurface == IntPtr.Zero)
        {
            return;
        }

        _focusService.InvalidateShellSurface(shellSurface);
        _shellSurfaceRegistry.Remove(shellSurface);

        // Guard against double-destroy: only act if we were still tracking the proxy. Untrack first so
        // a re-entrant dispatch can't see it as live.
        if (!_bindSiteState.ProxyInterface.Untrack(shellSurface))
        {
            return;
        }

        // Protocol: after destroyed the client must send the destroy request and stop using the
        // object. river_shell_surface_v1::destroy is opcode 0 and a destructor, so marshal it with
        // WL_MARSHAL_FLAG_DESTROY which also frees the local proxy.
        WaylandInterop.wl_proxy_marshal_flags(
            shellSurface, 0, IntPtr.Zero, 0, WaylandInterop.WL_MARSHAL_FLAG_DESTROY,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
    }

    public void HandlePointerEnterFocusFollow(IntPtr hoveredWindow, IntPtr seat)
    {
        RiverLog.Write("BRIDGE HandlePointerEnterFocusFollow hovered=0x" + hoveredWindow.ToString("x") + " seat=0x" + seat.ToString("x"));
        CancelPendingMouseFocus();
        if (!_layoutController.Config.Input.FocusFollowsMouse
            || hoveredWindow == IntPtr.Zero
            || hoveredWindow == _focusService.FocusedWindow
            || !_windowRegistry.TryGet(hoveredWindow, out var entry))
        {
            return;
        }

        var layoutId = _layoutController.ResolveLayoutId(entry.Output, null, entry.Tags);
        var opts = _layoutController.ResolveLayoutOptions(entry.Output, null, entry.Tags);
        var delayMs = layoutId == "scrolling" ? GetMouseFocusDelayMs(opts) : 0;
        if (delayMs <= 0)
        {
            _focusService.SetFocusedWindow(hoveredWindow, seat);
            return;
        }

        var cts = new CancellationTokenSource();
        lock (_pendingMouseFocusLock)
        {
            _pendingMouseFocus = cts;
        }

        _ = ApplyDelayedPointerFocus(hoveredWindow, seat, entry.Output, entry.Tags, delayMs, cts);
    }

    private static int GetMouseFocusDelayMs(LayoutOptions opts)
    {
        if (opts.Extra.TryGetValue("focus_follows_mouse_delay_ms", out var v)
            && int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out var delayMs))
        {
            return Math.Max(0, delayMs);
        }

        return 0;
    }

    private Task ApplyDelayedPointerFocus(IntPtr hoveredWindow, IntPtr seat, IntPtr output, uint tags, int delayMs, CancellationTokenSource cts)
        => Task.Delay(delayMs, cts.Token).ContinueWith(t =>
        {
            try
            {
                if (t.IsCanceled
                    || cts.IsCancellationRequested
                    || !_layoutController.Config.Input.FocusFollowsMouse
                    || hoveredWindow == _focusService.FocusedWindow
                    || !_windowRegistry.TryGet(hoveredWindow, out var entry)
                    || entry.Output != output
                    || entry.Tags != tags
                    || _layoutController.ResolveLayoutId(output, null, tags) != "scrolling")
                {
                    return;
                }

                _focusService.SetFocusedWindow(hoveredWindow, seat);
            }
            finally
            {
                lock (_pendingMouseFocusLock)
                {
                    if (ReferenceEquals(_pendingMouseFocus, cts))
                    {
                        _pendingMouseFocus = null;
                    }
                }

                cts.Dispose();
            }
        }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);

    private void CancelPendingMouseFocus()
    {
        CancellationTokenSource? cts;
        lock (_pendingMouseFocusLock)
        {
            cts = _pendingMouseFocus;
            _pendingMouseFocus = null;
        }

        cts?.Cancel();
    }

    public void HandleOpDelta(IntPtr seat, int dx, int dy)
    {
        RiverLog.Write("BRIDGE HandleOpDelta seat=0x" + seat.ToString("x") + " dx=" + dx + " dy=" + dy);
        var adw = _dragState.ActiveDragWindow;
        if (adw == null)
        {
            return;
        }

        // Drag (move or resize) is only meaningful while the float layout is active; in
        // tile/scrolling/monocle/grid the per- window Floating override is suppressed by LayoutProposer
        // bucketing and any FloatX/Y/W/H written here would be overwritten on the next manage cycle.
        // Treat a not-float OpDelta as an abandoned drag so the next legitimate drag starts clean.
        // Allow the live drag when the whole output is on the dedicated float engine OR this
        // specific window is an individually-floating popup/dialog overlaying a tiling layout.
        if (!(_layoutProposer.IsFloatLayoutActive(adw.Output) || adw.Floating))
        {
            _dragState.DragFinished = true;
            _managerRequestSender.ScheduleManage();
            return;
        }

        adw.Floating = true;

        uint dragEdges = _dragState.DragEdges;
        if (dragEdges == 0)
        {
            // --- Interactive move -----
            adw.X = _dragState.DragStartX + dx;
            adw.Y = _dragState.DragStartY + dy;
            adw.HasFloatRect = true;
            adw.FloatX = adw.X;
            adw.FloatY = adw.Y;
            int newFw = adw.W > 0 ? adw.W
                : adw.LastHintW > 0 ? adw.LastHintW
                : adw.ProposedW;
            int newFh = adw.H > 0 ? adw.H
                : adw.LastHintH > 0 ? adw.LastHintH
                : adw.ProposedH;
            if (newFw > 0)
            {
                adw.FloatW = newFw;
            }

            if (newFh > 0)
            {
                adw.FloatH = newFh;
            }

            _managerRequestSender.ScheduleManage();
        }
        else
        {
            // --- Interactive resize ----- Edges bitfield (river_window_v1): top=1, bottom=2, left=4,
            // right=8.
            int startX = _dragState.DragStartX;
            int startY = _dragState.DragStartY;
            int startW = _dragState.DragStartW;
            int startH = _dragState.DragStartH;
            int newX = startX;
            int newY = startY;
            int newW = startW;
            int newH = startH;

            if ((dragEdges & 8u) != 0) // right
            {
                newW = startW + dx;
            }
            else if ((dragEdges & 4u) != 0) // left
            {
                newW = startW - dx;
                newX = startX + dx;
            }

            if ((dragEdges & 2u) != 0) // bottom
            {
                newH = startH + dy;
            }
            else if ((dragEdges & 1u) != 0) // top
            {
                newH = startH - dy;
                newY = startY + dy;
            }

            // Clamp to client-advertised min/max hints. A hint value of 0 means "no preference" per the
            // protocol.
            int minW = adw.MinW > 0 ? adw.MinW : 1;
            int minH = adw.MinH > 0 ? adw.MinH : 1;
            if (newW < minW)
            {
                if ((dragEdges & 4u) != 0)
                {
                    newX = startX + (startW - minW);
                }

                newW = minW;
            }

            if (newH < minH)
            {
                if ((dragEdges & 1u) != 0)
                {
                    newY = startY + (startH - minH);
                }

                newH = minH;
            }

            if (adw.MaxW > 0 && newW > adw.MaxW)
            {
                if ((dragEdges & 4u) != 0)
                {
                    newX = startX + (startW - adw.MaxW);
                }

                newW = adw.MaxW;
            }

            if (adw.MaxH > 0 && newH > adw.MaxH)
            {
                if ((dragEdges & 1u) != 0)
                {
                    newY = startY + (startH - adw.MaxH);
                }

                newH = adw.MaxH;
            }

            adw.X = newX;
            adw.Y = newY;
            adw.HasFloatRect = true;
            adw.FloatX = newX;
            adw.FloatY = newY;
            adw.FloatW = newW;
            adw.FloatH = newH;

            _managerRequestSender.ScheduleManage();
        }
    }

    public void HandleOpRelease(IntPtr seat)
    {
        RiverLog.Write("BRIDGE HandleOpRelease seat=0x" + seat.ToString("x"));
        _dragState.DragFinished = true;
    }
}
