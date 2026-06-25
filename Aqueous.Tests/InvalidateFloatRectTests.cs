using System;
using System.Collections.Concurrent;
using System.Reflection;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Focus;
using Aqueous.Features.Layout;
using Aqueous.Features.State;
using Xunit;

namespace Aqueous.Tests;

/// <summary>
/// Tests for the host-side <see cref="WindowStateHost.InvalidateFloatRect"/> adapter. The adapter
/// is the only code path that flips <c>WindowEntry.HasFloatRect</c> back to <c>false</c> and
/// re-arms the position/size diff-gates the <c>LayoutProposer</c> floating loop guards on; if it
/// silently no-ops (as it did when the <c>TryGetValue</c> guard shipped inverted) the
/// maximize-button restore round-trip is broken.
/// <para>
/// rewritten to construct <see cref="WindowStateHost"/> directly with its 8 DI args (only <see
/// cref="IWindowRegistry"/> is touched by <c>InvalidateFloatRect</c> /
/// <c>SetToplevelMaximizedState</c>, so the other seven collaborators are passed as <c>null!</c>).
/// The previous reflection harness against <see cref="RiverWindowManagerClient"/> retires together
/// with the god class.
/// </para>
/// </summary>
public class InvalidateFloatRectTests
{
    private sealed class Harness
    {
        public required IWindowStateHost Host;
        public required ConcurrentDictionary<IntPtr, WindowEntry> Windows;
    }

    private static Harness Build()
    {
        var registry = new WindowRegistry();
        var host = new WindowStateHost(
            windowRegistry: registry,
            outputRegistry: new OutputRegistry(),
            windowStates: new WindowStateStore(),
            outputFullscreen: new OutputFullscreenMap(),
            focusedWindowTracker: new FocusedWindowTracker(),
            focusService: new NoopFocusService(),
            managerRequestSender: new NoopManagerRequestSender(),
            layoutController: new LayoutController(new LayoutRegistry(), new LayoutConfig()));
        return new Harness { Host = host, Windows = registry.Entries };
    }

    // Minimal IFocusService stub: InvalidateFloatRect / SetToplevelMaximizedState don't touch focus,
    // but the host ctor null-guards the collaborator. Every method is a no-op.
    private sealed class NoopFocusService : IFocusService
    {
        public IntPtr FocusedWindow => IntPtr.Zero;
        public bool TryGetFocusedAlive(out IntPtr proxy) { proxy = IntPtr.Zero; return false; }
        public void SetFocusedWindow(IntPtr windowProxy, IntPtr seatProxy) { }
        public void RequestFocus(IntPtr windowProxy) { }
        public void ClearFocus() { }
        public void FocusAnyOtherWindow(IntPtr avoid) { }
        public void FocusAnyOtherWindow(IntPtr avoid, IntPtr workspace) { }
        public void CycleFocus() { }
        public void HandleDirectionalFocus(FocusDirection dir) { }
        public void SetFocusedShellSurface(IntPtr shellSurfaceProxy, IntPtr seatProxy) { }
        public void InvalidateShellSurface(IntPtr shellSurfaceProxy) { }
        public void RepairFocusAfterTagChange() { }
        public void ClearFocusedHandle() { }
        public void ReassertFocusAfterLayerRelease() { }
    }

    // Minimal IManagerRequestSender stub: the host hooks under test do not marshal manager requests,
    // so every method is a no-op.
    private sealed class NoopManagerRequestSender : IManagerRequestSender
    {
        public void SendManagerRequest(uint opcode) { }
        public void ScheduleManage() { }
        public bool InsideManageSequence { get; set; }
        public void Init(IntPtr managerProxy, IntPtr display) { }
        public bool IsBound => false;
        public void Reset() { }
        public void SetPumpThread(int managedThreadId) { }
        public void DrainPumpQueue() { }
        public bool IsOnPumpThread => true;
        public void Post(Action action) => action();
        public void SetSeat(IntPtr seat) { }
        public void SuppressPointerConstraints(bool pressed) { }
    }

    [Fact]
    public void InvalidateFloatRect_ResetsAllFourGates()
    {
        var h = Build();
        var handle = new IntPtr(0xDEAD);
        var entry = new WindowEntry
        {
            HasFloatRect = true,
            LastPosX = 100,
            LastPosY = 200,
            LastHintW = 800,
            LastHintH = 600,
        };
        h.Windows[handle] = entry;

        h.Host.InvalidateFloatRect(new WindowProxy(handle));

        Assert.False(entry.HasFloatRect);
        Assert.NotEqual(100, entry.LastPosX);
        Assert.NotEqual(200, entry.LastPosY);
        Assert.NotEqual(800, entry.LastHintW);
        Assert.NotEqual(600, entry.LastHintH);
        // The entry itself must not have been removed.
        Assert.True(h.Windows.ContainsKey(handle));
    }

    [Fact]
    public void InvalidateFloatRect_SentinelsCannotMatchRealValues()
    {
        // The reset values must compare not-equal to any plausible real position/size so the
        // LayoutProposer diff-gates fire on the next cycle. Real values are non-negative for sizes;
        // positions can be negative on multi-output setups but never int.MinValue.
        var h = Build();
        var handle = new IntPtr(0xC0DE);
        var entry = new WindowEntry { HasFloatRect = true };
        h.Windows[handle] = entry;

        h.Host.InvalidateFloatRect(new WindowProxy(handle));

        // Position sentinels: must be < any real screen coordinate.
        Assert.True(entry.LastPosX <= -1_000_000);
        Assert.True(entry.LastPosY <= -1_000_000);
        // Size sentinels: must be != any positive width/height. Either 0 or int.MinValue satisfies the
        // diff-gate (`pw != LastHintW`).
        Assert.True(entry.LastHintW <= 0);
        Assert.True(entry.LastHintH <= 0);
    }

    [Fact]
    public void InvalidateFloatRect_UnknownHandle_IsNoOp()
    {
        var h = Build();
        var unknown = new IntPtr(0xBADD);

        // Must not throw, must not insert a phantom entry.
        h.Host.InvalidateFloatRect(new WindowProxy(unknown));

        Assert.False(h.Windows.ContainsKey(unknown));
    }

    [Fact]
    public void InvalidateFloatRect_ZeroProxy_IsNoOp()
    {
        var h = Build();
        // Zero handle is the documented "no window" sentinel; the host must tolerate it without throwing
        // or inserting an entry.
        h.Host.InvalidateFloatRect(WindowProxy.Zero);
        Assert.False(h.Windows.ContainsKey(IntPtr.Zero));
    }

    [Fact]
    public void InvalidateFloatRect_DoesNotTouchOtherEntries()
    {
        var h = Build();
        var target = new IntPtr(0xAA);
        var bystander = new IntPtr(0xBB);
        h.Windows[target] = new WindowEntry
        {
            HasFloatRect = true, LastPosX = 1, LastPosY = 2,
            LastHintW = 3, LastHintH = 4,
        };
        var keep = new WindowEntry
        {
            HasFloatRect = true, LastPosX = 11, LastPosY = 22,
            LastHintW = 33, LastHintH = 44,
        };
        h.Windows[bystander] = keep;

        h.Host.InvalidateFloatRect(new WindowProxy(target));

        Assert.True(keep.HasFloatRect);
        Assert.Equal(11, keep.LastPosX);
        Assert.Equal(22, keep.LastPosY);
        Assert.Equal(33, keep.LastHintW);
        Assert.Equal(44, keep.LastHintH);
    }

    // Installs a recording hook in place of the real wl_proxy_marshal_flags call inside
    // SetToplevelMaximizedState. Returns the recorder list and a disposable that restores the
    // previous hook (or null) on dispose so tests don't leak the override into one another.
    private static (System.Collections.Generic.List<(IntPtr handle, uint opcode)> log, IDisposable scope)
        InstallMarshalRecorder()
    {
        var hostType = typeof(WindowStateHost);
        var field = hostType.GetField("MaximizedMarshalOverride",
            BindingFlags.Static | BindingFlags.NonPublic);
        Assert.NotNull(field);

        var prev = field!.GetValue(null);
        var log = new System.Collections.Generic.List<(IntPtr, uint)>();
        Action<IntPtr, uint> hook = (h, op) => log.Add((h, op));
        field.SetValue(null, hook);
        return (log, new ResetScope(() => field.SetValue(null, prev)));
    }

    private sealed class ResetScope(Action onDispose) : IDisposable
    {
        public void Dispose() => onDispose();
    }

    [Fact]
    public void SetToplevelMaximizedState_TogglesXdgFlagAndRearmsSizeGate()
    {
        // Mirror of the Chromium / Alacritty fix: the host hook must flip the per-entry XdgMaximized flag
        // (consumed by any future xdg_toplevel.configure marshal) and re-arm the size diff-gate so a
        // fresh propose_dimensions goes out together with the new state array even if the size happens to
        // be unchanged.
        var (_, scope) = InstallMarshalRecorder();
        using var _s = scope;

        var h = Build();
        var handle = new IntPtr(0xBEEF);
        var entry = new WindowEntry
        {
            XdgMaximized = false,
            LastHintW = 1024,
            LastHintH = 768,
        };
        h.Windows[handle] = entry;

        h.Host.SetToplevelMaximizedState(new WindowProxy(handle), maximized: true);
        Assert.True(entry.XdgMaximized);
        Assert.NotEqual(1024, entry.LastHintW);
        Assert.NotEqual(768, entry.LastHintH);

        // Re-stamp Last* to plausible values, then drop maximized.
        entry.LastHintW = 1024;
        entry.LastHintH = 768;
        h.Host.SetToplevelMaximizedState(new WindowProxy(handle), maximized: false);
        Assert.False(entry.XdgMaximized);
        Assert.NotEqual(1024, entry.LastHintW);
        Assert.NotEqual(768, entry.LastHintH);
    }

    [Fact]
    public void SetToplevelMaximizedState_UnknownHandle_IsNoOp()
    {
        var (log, scope) = InstallMarshalRecorder();
        using var _s = scope;

        var h = Build();
        // Must tolerate unknown / zero proxies the same way InvalidateFloatRect does — and must NOT
        // marshal anything, since there's no entry to inform River about.
        h.Host.SetToplevelMaximizedState(new WindowProxy(new IntPtr(0xDEAD0)), true);
        h.Host.SetToplevelMaximizedState(WindowProxy.Zero, false);
        Assert.False(h.Windows.ContainsKey(new IntPtr(0xDEAD0)));
        Assert.False(h.Windows.ContainsKey(IntPtr.Zero));
        Assert.Empty(log);
    }

    [Fact]
    public void SetToplevelMaximizedState_MarshalsInformMaximizedOpcodes()
    {
        // The wire-level contract: enter must marshal opcode 15 (river_window_v1.inform_maximized) on the
        // window's proxy; restore must marshal opcode 16 (inform_unmaximized). Both are zero-arg requests
        // on the river_window_v1 proxy. Without these wire emits Chromium reconciles a stale state array
        // (3-click bug) and Alacritty refuses to leave maximized.
        var (log, scope) = InstallMarshalRecorder();
        using var _s = scope;

        var h = Build();
        var handle = new IntPtr(0xBEEF);
        h.Windows[handle] = new WindowEntry();

        h.Host.SetToplevelMaximizedState(new WindowProxy(handle), maximized: true);
        h.Host.SetToplevelMaximizedState(new WindowProxy(handle), maximized: false);

        Assert.Equal(2, log.Count);
        Assert.Equal((handle, 15u), log[0]);
        Assert.Equal((handle, 16u), log[1]);
    }

    [Fact]
    public void InvalidateFloatRect_IsIdempotent()
    {
        var h = Build();
        var handle = new IntPtr(0xF00D);
        var entry = new WindowEntry { HasFloatRect = true, LastPosX = 5, LastPosY = 6 };
        h.Windows[handle] = entry;

        h.Host.InvalidateFloatRect(new WindowProxy(handle));
        var pX = entry.LastPosX;
        var pY = entry.LastPosY;
        var hW = entry.LastHintW;
        var hH = entry.LastHintH;

        // Second call: no change, no throw.
        h.Host.InvalidateFloatRect(new WindowProxy(handle));

        Assert.False(entry.HasFloatRect);
        Assert.Equal(pX, entry.LastPosX);
        Assert.Equal(pY, entry.LastPosY);
        Assert.Equal(hW, entry.LastHintW);
        Assert.Equal(hH, entry.LastHintH);
    }
}
