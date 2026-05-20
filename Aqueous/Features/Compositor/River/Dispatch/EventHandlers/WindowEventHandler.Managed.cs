using System;
using Aqueous.Features.Compositor.River.Registry;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 9.7 — takes <see cref="RiverWindowManagerClient"/> directly,
/// retiring the transient <c>IWindowHandlerCollaborators</c> bridge.
/// Pump-thread only: invoked by <see cref="IEventDispatcher.Dispatch"/>.
/// </summary>
internal sealed unsafe class WindowEventHandler : IEventHandler
{
    private readonly IWindowRegistry _windows;
    private readonly RiverWindowManagerClient _river;
    private readonly Action<string>? _log;

    public WindowEventHandler(
        IWindowRegistry windows,
        RiverWindowManagerClient river,
        Action<string>? log = null)
    {
        _windows = windows ?? throw new ArgumentNullException(nameof(windows));
        _river = river ?? throw new ArgumentNullException(nameof(river));
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
        _river.HandleWindowEvent(proxy, ev.Opcode, args);
    }
}
