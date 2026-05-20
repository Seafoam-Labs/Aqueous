using System;
using Aqueous.Features.Screencopy;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// Managed <see cref="IEventHandler"/> for the <c>zwlr_screencopy_frame_v1</c> interface.
/// Per-frame proxies are owned by <c>WlrScreencopyClient</c> and tracked outside of
/// <c>_proxyInterface</c>; the native dispatcher therefore falls back to <see
/// cref="IScreencopyService.TryDispatchFrameEvent"/> directly for any target whose interface name
/// is unknown. This handler additionally exists so that, once frame proxies migrate into
/// <c>_proxyInterface</c>, interface-name routing collapses the fallback. Until then, this <see
/// cref="IEventHandler"/> is registered for completeness and as the documented routing target.
/// Bridge-less: depends only on <see cref="IScreencopyService"/>.
/// </summary>
internal sealed unsafe class ScreencopyFrameHandler : IEventHandler
{
    private readonly IScreencopyService _screencopy;
    private readonly Action<string>? _log;

    public ScreencopyFrameHandler(IScreencopyService screencopy, Action<string>? log = null)
    {
        ArgumentNullException.ThrowIfNull(screencopy);
        _screencopy = screencopy;
        _log = log;
    }

    public string InterfaceName => "zwlr_screencopy_frame_v1";

    public void Handle(WlEvent ev)
    {
        if (ev.Target == IntPtr.Zero)
        {
            _log?.Invoke("ScreencopyFrameHandler: zero target; opcode=" + ev.Opcode);
            return;
        }

        _screencopy.TryDispatchFrameEvent(
            ev.Target,
            ev.Opcode,
            ev.ArgsPtr == IntPtr.Zero ? null : (WlArgument*)ev.ArgsPtr);
    }
}
