using System;
using System.Collections.Concurrent;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Client-side adapter for the <c>wlr-screencopy-unstable-v1</c> protocol
/// that RiverDelta now advertises as a Wayland global.
///
/// <para>
/// This is the in-process screencopy path: callers (e.g. tag thumbnail
/// generation, snap-zone preview, debug screenshot tooling) hand us a
/// <c>wl_output</c> proxy and we drive the
/// <c>capture_output → buffer → buffer_done → copy → ready</c> handshake,
/// returning a managed RGBA byte array. For portal-based apps
/// (<c>xdg-desktop-portal-wlr</c>, browsers, OBS) Aqueous does not have to
/// proxy anything — those clients bind <c>zwlr_screencopy_manager_v1</c>
/// directly from RiverDelta.
/// </para>
///
/// <para>
/// Thread model: every public entry point here is invoked from the
/// libwayland dispatch thread (the same one running
/// <see cref="RiverWindowManagerClient"/>'s pump). The <see cref="CaptureOutputAsync"/>
/// flow registers a frame proxy, then resolves the <see cref="Task{TResult}"/>
/// from inside <see cref="OnFrameEvent"/> when the <c>ready</c> or
/// <c>failed</c> event arrives.
/// </para>
///
/// <para>
/// Buffer backing uses the <c>wl_shm</c> path with a <c>memfd_create</c>
/// fd — the simplest, AOT-friendly option that requires no extra runtime
/// dependencies. A DMA-BUF path can be added later behind the same public
/// surface; that requires <c>linux-dmabuf-unstable-v1</c> and <c>libgbm</c>.
/// </para>
/// </summary>
internal sealed unsafe partial class WlrScreencopyClient : IDisposable
{
    /// <summary>libc: <c>memfd_create(2)</c>. Used to allocate anonymous, sealable shm fds backing <c>wl_shm_pool</c>.</summary>
    [LibraryImport("libc", StringMarshalling = StringMarshalling.Utf8, SetLastError = true)]
    private static partial int memfd_create(string name, uint flags);

    /// <summary>libc: <c>ftruncate(2)</c>.</summary>
    [LibraryImport("libc", SetLastError = true)]
    private static partial int ftruncate(int fd, long length);

    /// <summary>libc: <c>mmap(2)</c>.</summary>
    [LibraryImport("libc", SetLastError = true)]
    private static partial IntPtr mmap(IntPtr addr, nuint length, int prot, int flags, int fd, long offset);

    /// <summary>libc: <c>munmap(2)</c>.</summary>
    [LibraryImport("libc", SetLastError = true)]
    private static partial int munmap(IntPtr addr, nuint length);

    /// <summary>libc: <c>close(2)</c>.</summary>
    [LibraryImport("libc", SetLastError = true)]
    private static partial int close(int fd);

    private const int PROT_READ = 0x1;
    private const int PROT_WRITE = 0x2;
    private const int MAP_SHARED = 0x01;
    private const uint MFD_CLOEXEC = 0x0001;

    private readonly IntPtr _manager;
    private readonly uint _version;
    private readonly IntPtr _shm;
    private readonly IntPtr _selfHandle;
    private readonly IntPtr _dispatcher;

    /// <summary>In-flight captures keyed by their <c>zwlr_screencopy_frame_v1</c> proxy handle.</summary>
    private readonly ConcurrentDictionary<IntPtr, FrameCapture> _frames = new();

    /// <summary>
    /// Constructs the screencopy client. Both <paramref name="manager"/> and
    /// <paramref name="shm"/> must already have been bound from the registry;
    /// the constructor does not bind anything itself.
    /// </summary>
    /// <param name="manager">A bound <c>zwlr_screencopy_manager_v1</c> proxy.</param>
    /// <param name="version">Negotiated manager version (1..3).</param>
    /// <param name="shm">A bound <c>wl_shm</c> proxy.</param>
    /// <param name="selfHandle">GCHandle (as IntPtr) routed to the dispatcher's implementation slot.</param>
    /// <param name="dispatcher">Function pointer for <see cref="WaylandInterop.wl_proxy_add_dispatcher"/>.</param>
    public WlrScreencopyClient(IntPtr manager, uint version, IntPtr shm, IntPtr selfHandle, IntPtr dispatcher)
    {
        _manager = manager;
        _version = version;
        _shm = shm;
        _selfHandle = selfHandle;
        _dispatcher = dispatcher;
    }

    /// <summary>
    /// Begins a full-output capture. Returns a task that completes with a
    /// freshly allocated RGBA-ish byte buffer (actual pixel format reported
    /// in <see cref="ScreencopyResult.Format"/>) once the compositor signals
    /// <c>ready</c>, or faults with <see cref="IOException"/> on
    /// <c>failed</c>.
    /// </summary>
    /// <param name="output">A <c>wl_output</c> proxy that the client already owns.</param>
    /// <param name="overlayCursor">When <c>true</c>, the cursor is composited into the captured frame.</param>
    /// <returns>Awaitable result describing the captured frame.</returns>
    /// <remarks>
    /// Must be invoked on the dispatch thread (or with a queue serialised
    /// against it). The caller is responsible for not destroying
    /// <paramref name="output"/> while the capture is in flight.
    /// </remarks>
    public Task<ScreencopyResult> CaptureOutputAsync(IntPtr output, bool overlayCursor = false)
    {
        if (_manager == IntPtr.Zero)
        {
            return Task.FromException<ScreencopyResult>(
                new InvalidOperationException("zwlr_screencopy_manager_v1 is not bound"));
        }
        if (_shm == IntPtr.Zero)
        {
            return Task.FromException<ScreencopyResult>(
                new InvalidOperationException("wl_shm is not bound"));
        }

        // capture_output(new_id<frame>, int overlay_cursor, object<wl_output>)
        var frame = WaylandInterop.wl_proxy_marshal_flags(
            _manager,
            RiverProtocolOpcodes.ScreencopyManager.CaptureOutput,
            (IntPtr)WlInterfaces.ZwlrScreencopyFrame,
            _version,
            0,
            IntPtr.Zero,                     // new_id slot — libwayland fills this
            (IntPtr)(overlayCursor ? 1 : 0),
            output,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

        if (frame == IntPtr.Zero)
        {
            return Task.FromException<ScreencopyResult>(
                new IOException("wl_proxy_marshal_flags(capture_output) returned null"));
        }

        // Attach our dispatcher so frame events flow back to OnFrameEvent.
        WaylandInterop.wl_proxy_add_dispatcher(frame, _dispatcher, _selfHandle, IntPtr.Zero);

        var capture = new FrameCapture(frame);
        _frames[frame] = capture;
        return capture.Completion.Task;
    }

    /// <summary>
    /// Routes a single libwayland event for an in-flight
    /// <c>zwlr_screencopy_frame_v1</c> proxy.
    /// </summary>
    /// <param name="frame">The frame proxy receiving the event.</param>
    /// <param name="opcode">Event opcode (see <see cref="RiverProtocolOpcodes.ScreencopyFrame"/>).</param>
    /// <param name="args">Pointer to the libwayland argument array.</param>
    /// <returns><c>true</c> when the proxy is known to this client and the event was consumed.</returns>
    /// <remarks>
    /// Called from the central <see cref="RiverWindowManagerClient"/>
    /// dispatcher; never throws into native code.
    /// </remarks>
    public bool OnFrameEvent(IntPtr frame, uint opcode, WlArgument* args)
    {
        if (!_frames.TryGetValue(frame, out var capture))
        {
            return false;
        }

        switch (opcode)
        {
            case RiverProtocolOpcodes.ScreencopyFrame.Buffer:
                // buffer(uint format, uint width, uint height, uint stride)
                capture.ShmFormat = args[0].u;
                capture.Width = args[1].u;
                capture.Height = args[2].u;
                capture.Stride = args[3].u;
                // For protocol v1/v2 there's no buffer_done, so allocate +
                // copy as soon as we see the buffer event. v3 waits for
                // buffer_done so it can also process linux_dmabuf.
                if (_version < 3)
                {
                    AllocateAndCopy(capture);
                }
                break;

            case RiverProtocolOpcodes.ScreencopyFrame.LinuxDmabuf:
                // Ignored: we always take the shm path. v3 only.
                break;

            case RiverProtocolOpcodes.ScreencopyFrame.BufferDone:
                AllocateAndCopy(capture);
                break;

            case RiverProtocolOpcodes.ScreencopyFrame.Flags:
                capture.Flags = args[0].u;
                break;

            case RiverProtocolOpcodes.ScreencopyFrame.Damage:
                // No-op for full captures; only meaningful for copy_with_damage.
                break;

            case RiverProtocolOpcodes.ScreencopyFrame.Ready:
                FinalizeReady(capture);
                break;

            case RiverProtocolOpcodes.ScreencopyFrame.Failed:
                FinalizeFailed(capture, "compositor reported zwlr_screencopy_frame_v1.failed");
                break;
        }

        return true;
    }

    private void AllocateAndCopy(FrameCapture capture)
    {
        if (capture.Buffer != IntPtr.Zero)
        {
            return; // already allocated (idempotent under v3 ordering quirks)
        }

        try
        {
            int size = checked((int)(capture.Stride * capture.Height));
            int fd = memfd_create("aqueous-screencopy", MFD_CLOEXEC);
            if (fd < 0)
            {
                FinalizeFailed(capture, $"memfd_create failed (errno={Marshal.GetLastWin32Error()})");
                return;
            }
            if (ftruncate(fd, size) != 0)
            {
                close(fd);
                FinalizeFailed(capture, $"ftruncate failed (errno={Marshal.GetLastWin32Error()})");
                return;
            }
            var map = mmap(IntPtr.Zero, (nuint)size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (map == new IntPtr(-1))
            {
                close(fd);
                FinalizeFailed(capture, $"mmap failed (errno={Marshal.GetLastWin32Error()})");
                return;
            }

            // wl_shm.create_pool(new_id<wl_shm_pool>, fd, size)
            var pool = WaylandInterop.wl_proxy_marshal_flags(
                _shm,
                RiverProtocolOpcodes.WlShm.CreatePool,
                (IntPtr)WlInterfaces.WlShmPool,
                1,
                0,
                IntPtr.Zero,
                (IntPtr)fd,
                (IntPtr)size,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

            // wl_shm_pool.create_buffer(new_id<wl_buffer>, offset, w, h, stride, format)
            var buffer = WaylandInterop.wl_proxy_marshal_flags(
                pool,
                RiverProtocolOpcodes.WlShmPool.CreateBuffer,
                (IntPtr)WlInterfaces.WlBuffer,
                1,
                0,
                IntPtr.Zero,
                IntPtr.Zero,
                (IntPtr)(int)capture.Width,
                (IntPtr)(int)capture.Height,
                (IntPtr)(int)capture.Stride,
                (IntPtr)capture.ShmFormat);

            // The pool can be torn down as soon as the buffer is created.
            WaylandInterop.wl_proxy_marshal_flags(
                pool,
                RiverProtocolOpcodes.WlShmPool.Destroy,
                IntPtr.Zero, 0,
                WaylandInterop.WL_MARSHAL_FLAG_DESTROY,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

            // We can close our fd: the kernel keeps the memfd alive via mmap.
            close(fd);

            capture.Buffer = buffer;
            capture.Map = map;
            capture.MapSize = size;

            // zwlr_screencopy_frame_v1.copy(buffer)
            WaylandInterop.wl_proxy_marshal_flags(
                capture.Frame,
                RiverProtocolOpcodes.ScreencopyFrameRequest.Copy,
                IntPtr.Zero, 0, 0,
                buffer,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        }
        catch (Exception e)
        {
            FinalizeFailed(capture, "AllocateAndCopy threw: " + e.Message);
        }
    }

    private void FinalizeReady(FrameCapture capture)
    {
        try
        {
            var pixels = new byte[capture.MapSize];
            Marshal.Copy(capture.Map, pixels, 0, capture.MapSize);

            var result = new ScreencopyResult(
                pixels,
                (int)capture.Width,
                (int)capture.Height,
                (int)capture.Stride,
                capture.ShmFormat,
                capture.Flags);

            CleanupCapture(capture);
            capture.Completion.TrySetResult(result);
        }
        catch (Exception e)
        {
            FinalizeFailed(capture, "FinalizeReady threw: " + e.Message);
        }
    }

    private void FinalizeFailed(FrameCapture capture, string reason)
    {
        CleanupCapture(capture);
        capture.Completion.TrySetException(new IOException(reason));
    }

    private void CleanupCapture(FrameCapture capture)
    {
        _frames.TryRemove(capture.Frame, out _);

        if (capture.Buffer != IntPtr.Zero)
        {
            WaylandInterop.wl_proxy_marshal_flags(
                capture.Buffer,
                RiverProtocolOpcodes.WlBuffer.Destroy,
                IntPtr.Zero, 0,
                WaylandInterop.WL_MARSHAL_FLAG_DESTROY,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            capture.Buffer = IntPtr.Zero;
        }

        if (capture.Map != IntPtr.Zero && capture.MapSize > 0)
        {
            munmap(capture.Map, (nuint)capture.MapSize);
            capture.Map = IntPtr.Zero;
        }

        // zwlr_screencopy_frame_v1.destroy()
        WaylandInterop.wl_proxy_marshal_flags(
            capture.Frame,
            RiverProtocolOpcodes.ScreencopyFrameRequest.Destroy,
            IntPtr.Zero, 0,
            WaylandInterop.WL_MARSHAL_FLAG_DESTROY,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
    }

    public void Dispose()
    {
        foreach (var kv in _frames)
        {
            FinalizeFailed(kv.Value, "WlrScreencopyClient disposed");
        }
        _frames.Clear();

        if (_manager != IntPtr.Zero)
        {
            WaylandInterop.wl_proxy_marshal_flags(
                _manager,
                RiverProtocolOpcodes.ScreencopyManager.Destroy,
                IntPtr.Zero, 0,
                WaylandInterop.WL_MARSHAL_FLAG_DESTROY,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        }
    }

    /// <summary>Per-capture state held between <c>capture_output</c> and <c>ready</c>.</summary>
    private sealed class FrameCapture
    {
        public FrameCapture(IntPtr frame)
        {
            Frame = frame;
            Completion = new TaskCompletionSource<ScreencopyResult>(
                TaskCreationOptions.RunContinuationsAsynchronously);
        }

        public IntPtr Frame { get; }
        public TaskCompletionSource<ScreencopyResult> Completion { get; }

        public uint ShmFormat;
        public uint Width;
        public uint Height;
        public uint Stride;
        public uint Flags;

        public IntPtr Buffer;
        public IntPtr Map;
        public int MapSize;
    }
}

/// <summary>
/// Successful result of a <see cref="WlrScreencopyClient.CaptureOutputAsync"/> call.
/// </summary>
/// <param name="Pixels">Raw pixel bytes (length = <paramref name="Stride"/> × <paramref name="Height"/>).</param>
/// <param name="Width">Image width in pixels.</param>
/// <param name="Height">Image height in pixels.</param>
/// <param name="Stride">Row stride in bytes.</param>
/// <param name="ShmFormat">The <c>wl_shm</c> format enum reported by the compositor (e.g. XRGB8888 = 1).</param>
/// <param name="Flags">
/// <c>zwlr_screencopy_frame_v1.flags</c> bitset. Currently the only
/// defined bit is <c>Y_INVERT</c> (1) — when set, the rows are bottom-up.
/// </param>
internal readonly record struct ScreencopyResult(
    byte[] Pixels,
    int Width,
    int Height,
    int Stride,
    uint ShmFormat,
    uint Flags);
