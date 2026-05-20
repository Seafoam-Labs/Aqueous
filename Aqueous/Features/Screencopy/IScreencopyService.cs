using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Connection;

namespace Aqueous.Features.Screencopy;

/// <summary>
/// Stage 6 Part 2 — managed seam over <see cref="WlrScreencopyClient"/>.
/// Owns the screencopy client lifecycle (lazy-bind once both wl_shm and
/// zwlr_screencopy_manager_v1 globals are present) and routes per-frame
/// native callback events into the underlying client.
/// </summary>
internal interface IScreencopyService
{
    /// <summary>True once both wl_shm and zwlr_screencopy_manager_v1 have been bound.</summary>
    bool IsReady { get; }

    /// <summary>
    /// Capture a specific output proxy. Returns <c>null</c> if the service is not yet ready.
    /// </summary>
    Task<ScreencopyResult>? CaptureOutputAsync(IntPtr output, bool overlayCursor = false);

    /// <summary>
    /// Pump-thread; route a native frame event. Returns <c>true</c> if the event was consumed
    /// by the underlying screencopy client.
    /// </summary>
    unsafe bool TryDispatchFrameEvent(IntPtr frame, uint opcode, WlArgument* args);

    /// <summary>
    /// Idempotently constructs the underlying <see cref="WlrScreencopyClient"/> once both
    /// <c>wl_shm</c> and <c>zwlr_screencopy_manager_v1</c> globals are present. Safe to
    /// call from either bind-site as their arrival order is not guaranteed.
    /// </summary>
    void TryActivate(IntPtr screencopyManager, uint version, IntPtr shm, IntPtr selfHandle, IntPtr dispatcher);

    /// <summary>
    /// PR 9.12 §2.11 — picks the first known <c>wl_output</c> global from
    /// <paramref name="outputGlobals"/>, binds it via <paramref name="bindOutput"/>
    /// (typically <c>IWaylandConnection.Registry.Bind</c>), captures a single
    /// frame, then destroys the proxy via <paramref name="destroyProxy"/>.
    /// Returns <c>null</c> if the service is not ready or no output globals
    /// are present.
    /// </summary>
    Task<ScreencopyResult>? CaptureFirstOutputAsync(
        IEnumerable<RegistryGlobal> outputGlobals,
        Func<uint, IntPtr> bindOutput,
        Action<IntPtr> destroyProxy,
        bool overlayCursor = false);
}
