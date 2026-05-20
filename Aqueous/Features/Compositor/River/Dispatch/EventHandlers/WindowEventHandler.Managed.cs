using System;
using Aqueous.Features.Compositor.River.Dispatch.Services;
using Aqueous.Features.Compositor.River.Registry;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 9.12 §2.13 — takes <see cref="WindowEventService"/> directly;
/// the prior <c>RiverWindowManagerClient</c> reference (and the
/// partial-class <c>WindowEventHandler.cs</c> file that backed it)
/// have been retired.
/// Pump-thread only: invoked by <see cref="IEventDispatcher.Dispatch"/>.
/// </summary>
internal sealed unsafe class WindowEventHandler : IEventHandler
{
    private readonly IWindowRegistry _windows;
    private readonly WindowEventService _service;
    private readonly Action<string>? _log;

    public WindowEventHandler(
        IWindowRegistry windows,
        WindowEventService service,
        Action<string>? log = null)
    {
        _windows = windows ?? throw new ArgumentNullException(nameof(windows));
        _service = service ?? throw new ArgumentNullException(nameof(service));
        _log = log;
    }

    public string InterfaceName => "river_window_v1";

    public void Handle(WlEvent ev)
    {
        IntPtr proxy = ev.Target;
        if (!_windows.Entries.ContainsKey(proxy))
        {
            return;
        }
        WlArgument* args = ev.ArgsPtr == IntPtr.Zero ? null : (WlArgument*)ev.ArgsPtr;
        _service.HandleEvent(proxy, ev.Opcode, args);
    }
}
