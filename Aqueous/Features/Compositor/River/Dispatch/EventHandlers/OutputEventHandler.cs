using System;
using System.Collections.Generic;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.State;
namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
/// <summary>
/// Second <see cref="IEventHandler"/> extracted out of the <c>RiverWindowManagerClient</c> god
/// class. ctor no longer takes <c>RiverWindowManagerClient</c>; removed-path state is read from
/// fine-grained singletons (<see cref="WindowStateStore"/>, <see cref="WindowStateController"/>,
/// <see cref="OutputFullscreenMap"/>). The handler now has zero class coupling. Pump-thread only:
/// invoked by <see cref="IEventDispatcher.Dispatch"/>.
/// </summary>
internal sealed unsafe class OutputEventHandler : IEventHandler
{
    private readonly IWindowRegistry _windows;
    private readonly IOutputRegistry _outputs;
    private readonly WindowStateStore _windowStates;
    private readonly WindowStateController _windowState;
    private readonly OutputFullscreenMap _outputFullscreen;
    private readonly Action<string>? _log;
    public OutputEventHandler(
        IWindowRegistry windows,
        IOutputRegistry outputs,
        WindowStateStore windowStates,
        WindowStateController windowState,
        OutputFullscreenMap outputFullscreen,
        Action<string>? log = null)
    {
        _windows = windows ?? throw new ArgumentNullException(nameof(windows));
        _outputs = outputs ?? throw new ArgumentNullException(nameof(outputs));
        _windowStates = windowStates ?? throw new ArgumentNullException(nameof(windowStates));
        _windowState = windowState ?? throw new ArgumentNullException(nameof(windowState));
        _outputFullscreen = outputFullscreen ?? throw new ArgumentNullException(nameof(outputFullscreen));
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
        foreach (var ws in _windowStates.Snapshot())
        {
            if (ws.PinnedOutput == outputProxy)
            {
                goneOutputWindows.Add(ws);
            }
        }
        _windowState.OnOutputRemoved(outputProxy, goneOutputWindows);
        _outputFullscreen.TryRemove(proxy, out _);
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
