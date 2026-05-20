using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Connection;

namespace Aqueous.Features.Screencopy;

/// <summary>
/// Stage 6 Part 2 facade — owns the <see cref="WlrScreencopyClient"/> instance
/// and routes the screencopy branch of the native callback. No collaborator
/// bridge is required: the service has no callbacks back into
/// <c>RiverWindowManagerClient</c> (first bridge-less Stage in the
/// decomposition).
/// </summary>
internal sealed class ScreencopyService : IScreencopyService, IDisposable
{
    /// <summary>
    /// Test seam only — overrides the <see cref="WlrScreencopyClient"/>
    /// constructor used by <see cref="TryActivate"/>. Production callers must
    /// never set this; it exists exclusively so unit tests can avoid
    /// constructing the real (P/Invoke-heavy) client.
    /// </summary>
    internal Func<IntPtr, uint, IntPtr, IntPtr, IntPtr, WlrScreencopyClient?>? ClientFactory { get; init; }

    private WlrScreencopyClient? _client;

    public bool IsReady => _client is not null;

    public void TryActivate(IntPtr screencopyManager, uint version, IntPtr shm, IntPtr selfHandle, IntPtr dispatcher)
    {
        if (_client is not null)
        {
            return;
        }

        if (screencopyManager == IntPtr.Zero || shm == IntPtr.Zero)
        {
            return;
        }

        if (ClientFactory is { } factory)
        {
            _client = factory(screencopyManager, version, shm, selfHandle, dispatcher);
        }
        else
        {
            _client = new WlrScreencopyClient(screencopyManager, version, shm, selfHandle, dispatcher);
        }
    }

    public void ActivateIfReady(
        WaylandBindSiteState bindSite,
        uint screencopyVersion,
        IntPtr selfHandle,
        IntPtr dispatcher,
        Action<string> log)
    {
        if (bindSite is null) throw new ArgumentNullException(nameof(bindSite));
        if (log is null) throw new ArgumentNullException(nameof(log));

        bool wasReady = IsReady;
        TryActivate(bindSite.ScreencopyManager, screencopyVersion, bindSite.WlShm, selfHandle, dispatcher);
        if (!wasReady && IsReady)
        {
            log("screencopy ready (wl_shm + zwlr_screencopy_manager_v1)");
        }
    }

    public Task<ScreencopyResult>? CaptureOutputAsync(IntPtr output, bool overlayCursor = false)
        => _client?.CaptureOutputAsync(output, overlayCursor);

    public Task<ScreencopyResult>? CaptureFirstOutputAsync(
        IEnumerable<RegistryGlobal> outputGlobals,
        Func<uint, IntPtr> bindOutput,
        Action<IntPtr> destroyProxy,
        bool overlayCursor = false)
    {
        if (!IsReady)
        {
            return null;
        }

        RegistryGlobal? pick = null;
        foreach (var g in outputGlobals)
        {
            pick = g;
            break;
        }

        if (pick is null)
        {
            return null;
        }

        IntPtr output = bindOutput(pick.Value.Name);
        if (output == IntPtr.Zero)
        {
            return null;
        }

        var task = CaptureOutputAsync(output, overlayCursor);
        if (task is null)
        {
            destroyProxy(output);
            return null;
        }

        IntPtr captured = output;
        return task.ContinueWith((t, state) =>
        {
            destroyProxy((IntPtr)state!);
            return t.GetAwaiter().GetResult();
        }, captured, TaskScheduler.Default);
    }

    public unsafe bool TryDispatchFrameEvent(IntPtr frame, uint opcode, WlArgument* args)
        => _client is not null && _client.OnFrameEvent(frame, opcode, args);

    public void Dispose()
    {
        _client?.Dispose();
        _client = null;
    }
}
