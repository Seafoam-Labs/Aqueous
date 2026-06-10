using System;
using System.Collections.Concurrent;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Connection;

namespace Aqueous.Features.Input;

/// <summary>
/// Owns the bound <c>river_xkb_config_v1</c> global and pushes the <c>[input] xkb_*</c> keymap from
/// <c>wm.toml</c> to every keyboard the compositor announces.
/// <para>
/// Lifecycle: <see cref="Apply"/> stores the latest <see cref="InputConfig"/> (called once at
/// startup and again on every <c>wm.toml</c> reload). <see cref="OnBound"/> is invoked from
/// <c>RiverCompositorHost.HandleRegistryGlobal</c> when the global appears; it captures the
/// dispatcher seam needed to install event routing on the keymap proxy and triggers the first
/// compile. <see cref="OnKeyboardAdded"/>/<see cref="OnKeyboardRemoved"/> are driven by the xkb
/// event handlers, and <see cref="OnKeymapSuccess"/>/<see cref="OnKeymapFailure"/> by the keymap
/// result events.
/// </para>
/// <para>
/// All entry points run on the libwayland dispatch (pump) thread, except the startup
/// <see cref="Apply"/> which runs before the pump starts (when the proxy is still zero, so it only
/// stores the config). A lock guards the shared fields regardless.
/// </para>
/// </summary>
internal sealed unsafe class XkbConfigApplier
{
    private readonly object _lock = new();
    private readonly WaylandBindSiteState _bindSiteState;
    private readonly ConcurrentDictionary<IntPtr, byte> _keyboards = new();

    private InputConfig _config = InputConfig.Default;
    private IntPtr _config_proxy;
    private IntPtr _dispatcher;
    private IntPtr _dispatcherImpl;

    // The keymap object we are currently waiting on a success/failure for.
    private IntPtr _pendingKeymap;
    // The keymap object that received `success` and may be passed to set_keymap.
    private IntPtr _activeKeymap;

    public XkbConfigApplier(WaylandBindSiteState bindSiteState)
    {
        _bindSiteState = bindSiteState ?? throw new ArgumentNullException(nameof(bindSiteState));
    }

    /// <summary>
    /// Called from <c>RiverCompositorHost</c> after the global is bound. Captures the proxy and the
    /// native-dispatcher seam (function pointer + implementation handle) so the keymap proxies this
    /// applier creates route their <c>success</c>/<c>failure</c> events back in.
    /// </summary>
    public void OnBound(IntPtr configProxy, IntPtr dispatcher, IntPtr dispatcherImpl)
    {
        lock (_lock)
        {
            _config_proxy = configProxy;
            _dispatcher = dispatcher;
            _dispatcherImpl = dispatcherImpl;
        }

        RiverLog.Write("river_xkb_config_v1 bound; compiling keymap");
        CreateKeymap();
    }

    /// <summary>
    /// Store a fresh <see cref="InputConfig"/> and (re)compile the keymap if the global is already
    /// bound. Called on startup and on <c>wm.toml</c> reload.
    /// </summary>
    public void Apply(InputConfig cfg)
    {
        lock (_lock) _config = cfg;
        if (_config_proxy != IntPtr.Zero)
        {
            CreateKeymap();
        }
    }

    /// <summary>
    /// Called by <c>XkbConfigEventHandler</c> when the compositor announces a new keyboard. If a
    /// keymap is already active, apply it immediately; otherwise it will be applied on the next
    /// <c>success</c>.
    /// </summary>
    public void OnKeyboardAdded(IntPtr keyboardProxy)
    {
        if (keyboardProxy == IntPtr.Zero) return;
        _keyboards[keyboardProxy] = 0;

        IntPtr keymap;
        lock (_lock) keymap = _activeKeymap;
        if (keymap != IntPtr.Zero)
        {
            SetKeymap(keyboardProxy, keymap);
        }
    }

    public void OnKeyboardRemoved(IntPtr keyboardProxy)
    {
        _keyboards.TryRemove(keyboardProxy, out _);
    }

    /// <summary>
    /// Called by <c>XkbKeymapEventHandler</c> on <c>success</c>: promote the pending keymap to active
    /// and push it to every known keyboard.
    /// </summary>
    public void OnKeymapSuccess(IntPtr keymapProxy)
    {
        lock (_lock)
        {
            if (keymapProxy != _pendingKeymap)
            {
                return; // stale result for a superseded keymap.
            }
            _activeKeymap = keymapProxy;
            _pendingKeymap = IntPtr.Zero;
        }

        RiverLog.Write($"xkb keymap 0x{keymapProxy.ToString("x")} ready; applying to {_keyboards.Count} keyboard(s)");
        foreach (var kb in _keyboards.Keys)
        {
            SetKeymap(kb, keymapProxy);
        }
    }

    /// <summary>
    /// Called by <c>XkbKeymapEventHandler</c> on <c>failure</c>: log and drop the pending keymap.
    /// </summary>
    public void OnKeymapFailure(IntPtr keymapProxy, string? errorMsg)
    {
        RiverLog.Write($"xkb keymap 0x{keymapProxy.ToString("x")} failed: {errorMsg ?? "<no message>"}");
        lock (_lock)
        {
            if (keymapProxy == _pendingKeymap)
            {
                _pendingKeymap = IntPtr.Zero;
            }
        }
    }

    // ---- Wire helpers ------------------------------------------------

    private void CreateKeymap()
    {
        InputConfig cfg;
        IntPtr config;
        IntPtr dispatcher;
        IntPtr impl;
        lock (_lock)
        {
            cfg = _config;
            config = _config_proxy;
            dispatcher = _dispatcher;
            impl = _dispatcherImpl;
        }

        if (config == IntPtr.Zero)
        {
            return;
        }

        if (!XkbKeymapCompiler.TryCompileToFd(cfg, out int fd))
        {
            // Compilation failed/logged; keep any previously active keymap in place.
            return;
        }

        try
        {
            // river_xkb_config_v1.create_keymap(new_id<keymap>, fd, format). The new_id is filled
            // implicitly (iface != null), so the explicit arg slots are fd then format.
            IntPtr keymap = WaylandInterop.wl_proxy_marshal_flags(
                config, RiverProtocolOpcodes.XkbConfigRequest.CreateKeymap,
                (IntPtr)WlInterfaces.RiverXkbKeymap, 2, 0,
                IntPtr.Zero, (IntPtr)fd, (IntPtr)RiverProtocolOpcodes.XkbKeymapFormat.TextV1,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

            if (keymap == IntPtr.Zero)
            {
                RiverLog.Write("xkb: create_keymap returned null proxy");
                return;
            }

            _bindSiteState.TrackProxyInterface(keymap, "river_xkb_keymap_v1");
            if (dispatcher != IntPtr.Zero)
            {
                WaylandInterop.wl_proxy_add_dispatcher(keymap, dispatcher, impl, IntPtr.Zero);
            }

            lock (_lock) _pendingKeymap = keymap;
            RiverLog.Write($"xkb: create_keymap -> 0x{keymap.ToString("x")} (awaiting success)");
        }
        finally
        {
            // The compositor dup()s the fd during create_keymap; we own and must close our copy.
            XkbKeymapCompiler.CloseFd(fd);
        }
    }

    private void SetKeymap(IntPtr keyboardProxy, IntPtr keymapProxy)
    {
        if (keyboardProxy == IntPtr.Zero || keymapProxy == IntPtr.Zero) return;

        // river_xkb_keyboard_v1.set_keymap(object<keymap>): single object arg in slot 0.
        WaylandInterop.wl_proxy_marshal_flags(
            keyboardProxy, RiverProtocolOpcodes.XkbKeyboardRequest.SetKeymap, IntPtr.Zero, 0, 0,
            keymapProxy, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

        RiverLog.Write($"xkb set_keymap keyboard 0x{keyboardProxy.ToString("x")} -> 0x{keymapProxy.ToString("x")}");
    }
}
