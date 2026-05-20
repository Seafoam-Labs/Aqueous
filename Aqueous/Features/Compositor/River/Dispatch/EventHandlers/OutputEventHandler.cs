using System;
using System.Collections.Generic;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.State;
namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
/// <summary>
/// PR 8.2 — second <see cref="IEventHandler"/> extracted out of the
/// <c>RiverWindowManagerClient</c> god class. PR 9.8 retired the
/// <c>IOutputHandlerCollaborators</c> bridge: the removed-path now
/// reaches god-class state via internal pass-through accessors on
/// <see cref="RiverWindowManagerClient"/>.
///
/// Pump-thread only: invoked by <see cref="IEventDispatcher.Dispatch"/>.
/// </summary>
internal sealed unsafe class OutputEventHandler : IEventHandler
{
    private readonly IWindowRegistry _windows;
    private readonly IOutputRegistry _outputs;
    private readonly RiverWindowManagerClient _river;
    private readonly Action<string>? _log;
    public OutputEventHandler(
        IWindowRegistry windows,
        IOutputRegistry outputs,
        RiverWindowManagerClient river,
        Action<string>? log = null)
    {
        _windows = windows ?? throw new ArgumentNullException(nameof(windows));
        _outputs = outputs ?? throw new ArgumentNullException(nameof(outputs));
        _river = river ?? throw new ArgumentNullException(nameof(river));
        _log = log;
    }
    public string InterfaceName => "river_output_v1";
    public void Handle(WlEvent ev)
    {
        IntPtr proxy = ev.Target;
        if (!_outputs.Entries.TryGetValue(proxy, out var o))
        {
            return;
        }
        switch (ev.Opcode)
        {
            case RiverProtocolOpcodes.Output.Removed:
                HandleRemoved(proxy);
                break;
            case RiverProtocolOpcodes.Output.WlOutput:
                if (ev.ArgsPtr == IntPtr.Zero || ev.ArgCount < 1) return;
                {
                    var args = (WlArgument*)ev.ArgsPtr;
                    o.WlOutputName = args[0].u;
                    _log?.Invoke("output 0x" + proxy.ToString("x") + " wl_output_name=" + o.WlOutputName);
                }
                break;
            case RiverProtocolOpcodes.Output.Position:
                if (ev.ArgsPtr == IntPtr.Zero || ev.ArgCount < 2) return;
                {
                    var args = (WlArgument*)ev.ArgsPtr;
                    o.X = args[0].i;
                    o.Y = args[1].i;
                    _log?.Invoke("output 0x" + proxy.ToString("x") + " position=" + o.X + "," + o.Y);
                }
                break;
            case RiverProtocolOpcodes.Output.Dimensions:
                if (ev.ArgsPtr == IntPtr.Zero || ev.ArgCount < 2) return;
                {
                    var args = (WlArgument*)ev.ArgsPtr;
                    o.Width = args[0].i;
                    o.Height = args[1].i;
                    _log?.Invoke("output 0x" + proxy.ToString("x") + " dimensions=" + o.Width + "x" + o.Height);
                }
                break;
        }
    }
    private void HandleRemoved(IntPtr proxy)
    {
        _log?.Invoke("output 0x" + proxy.ToString("x") + " removed");
        var goneOutputWindows = new List<WindowStateData>();
        var outputProxy = new OutputProxy(proxy);
        foreach (var ws in _river.SnapshotWindowStates())
        {
            if (ws.PinnedOutput == outputProxy)
            {
                goneOutputWindows.Add(ws);
            }
        }
        _river.OnOutputRemovedForwarding(outputProxy, goneOutputWindows);
        _river.OutputFullscreenTryRemove(proxy);
        _outputs.Entries.TryRemove(proxy, out _);
        foreach (var wkvp in _windows.Entries)
        {
            if (wkvp.Value.Output == proxy)
            {
                wkvp.Value.Output = IntPtr.Zero;
            }
        }
    }
}
