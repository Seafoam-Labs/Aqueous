using System;
using System.Collections.Generic;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.State;
using Aqueous.Features.Layout;
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
    private readonly WaylandBindSiteState _bindSiteState;
    private readonly WindowStateStore _windowStates;
    private readonly WindowStateController _windowState;
    private readonly OutputFullscreenMap _outputFullscreen;
    private readonly ILayerShellTeardownService _layerShellTeardown;
    private readonly IManagerRequestSender _managerRequestSender;
    private readonly Action<string>? _log;
    public OutputEventHandler(
        IWindowRegistry windows,
        IOutputRegistry outputs,
        WaylandBindSiteState bindSiteState,
        WindowStateStore windowStates,
        WindowStateController windowState,
        OutputFullscreenMap outputFullscreen,
        ILayerShellTeardownService layerShellTeardown,
        IManagerRequestSender managerRequestSender,
        Action<string>? log = null)
    {
        _windows = windows ?? throw new ArgumentNullException(nameof(windows));
        _outputs = outputs ?? throw new ArgumentNullException(nameof(outputs));
        _bindSiteState = bindSiteState ?? throw new ArgumentNullException(nameof(bindSiteState));
        _windowStates = windowStates ?? throw new ArgumentNullException(nameof(windowStates));
        _windowState = windowState ?? throw new ArgumentNullException(nameof(windowState));
        _outputFullscreen = outputFullscreen ?? throw new ArgumentNullException(nameof(outputFullscreen));
        _layerShellTeardown = layerShellTeardown ?? throw new ArgumentNullException(nameof(layerShellTeardown));
        _managerRequestSender = managerRequestSender ?? throw new ArgumentNullException(nameof(managerRequestSender));
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
                    if (_bindSiteState.WlOutputProxies.TryGetValue(o.WlOutputName, out var wlProxy))
                    {
                        o.WlOutput = wlProxy;
                    }
                    _log?.Invoke("output 0x" + proxy.ToString("x") + " wl_output_name=" + o.WlOutputName);
                }
                break;
            case RiverProtocolOpcodes.Output.Position:
                if (ev.ArgsPtr == IntPtr.Zero || ev.ArgCount < 2) return;
                {
                    var args = (WlArgument*)ev.ArgsPtr;
                    int newX = args[0].i;
                    int newY = args[1].i;
                    bool changed = o.X != newX || o.Y != newY;
                    o.X = newX;
                    o.Y = newY;
                    _log?.Invoke("output 0x" + proxy.ToString("x") + " position=" + o.X + "," + o.Y);
                    if (changed)
                    {
                        InvalidateWindowGeometryCaches(proxy);
                        _managerRequestSender.ScheduleManage();
                    }
                }
                break;
            case RiverProtocolOpcodes.Output.Dimensions:
                if (ev.ArgsPtr == IntPtr.Zero || ev.ArgCount < 2) return;
                {
                    var args = (WlArgument*)ev.ArgsPtr;
                    int newW = args[0].i;
                    int newH = args[1].i;
                    bool changed = o.Width != newW || o.Height != newH;
                    o.Width = newW;
                    o.Height = newH;
                    _log?.Invoke("output 0x" + proxy.ToString("x") + " dimensions=" + o.Width + "x" + o.Height);
                    // Once the real output size is known, re-run a layout pass so any window that was
                    // mapped/arranged against the stale 1920x1080 guess gets re-arranged. Invalidate
                    // the per-window geometry caches first, otherwise the propose pass short-circuits
                    // on unchanged cached numbers and the surface keeps its wrong first-open size.
                    if (changed)
                    {
                        InvalidateWindowGeometryCaches(proxy);
                        _managerRequestSender.ScheduleManage();
                    }
                }
                break;
        }
    }
    /// <summary>
    /// Reset the per-window geometry caches (<c>LastHintW/H</c>, <c>LastPosX/Y</c>, <c>LastClipW/H</c>)
    /// for every window assigned to <paramref name="output"/>. Mirrors the engine-swap invalidation in
    /// <c>LayoutProposer.ProposeForArea</c> so a re-propose triggered by an output geometry change is
    /// not short-circuited by stale cached numbers.
    /// </summary>
    private void InvalidateWindowGeometryCaches(IntPtr output)
    {
        foreach (var kvp in _windows.Entries)
        {
            var w = kvp.Value;
            if (w.Output != output) continue;
            w.LastHintW = 0;
            w.LastHintH = 0;
            w.LastPosX = int.MinValue;
            w.LastPosY = int.MinValue;
            w.LastClipW = 0;
            w.LastClipH = 0;
        }
    }
    private void HandleRemoved(IntPtr proxy)
    {
        _log?.Invoke("output 0x" + proxy.ToString("x") + " removed");
        // Destroy the per-output river_layer_shell_output_v1 sub-object (now inert) and drop
        // its stored usable-area hint before forgetting the output.
        _layerShellTeardown.TeardownOutput(proxy);
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
