using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Diagnostics;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Aqueous.Features.Compositor.River.Connection;

/// <summary>
/// Owns the lifetime of a single <c>wl_display</c> connection plus the thin set of
/// <c>libwayland-client</c> calls that operate on it (connect / disconnect / dispatch / roundtrip
/// / flush / file descriptor). Higher layers should treat this class as the only place where raw
/// <c>wl_display</c> pointers are created or destroyed.
/// </summary>
/// <remarks>
/// This type is intentionally state-only: it does not manage the registry, the dispatcher
/// callback, or the pump thread. Those concerns live in <see
/// cref="Aqueous.Features.Compositor.River.RiverWindowManagerClient"/> (registry / dispatcher) and
/// <see cref="EventPump"/> (pump thread).
/// </remarks>
internal sealed class WaylandConnection : IWaylandConnection
{
    private readonly ILogger<WaylandConnection> _logger;
    private readonly WaylandOptions _options;

    /// <summary>
    /// Guards single-fire semantics for <see cref="Disconnected"/>.
    /// </summary>
    private int _disconnectedRaised;

    public IntPtr Display { get; private set; }

    public bool IsConnected => Display != IntPtr.Zero;

    public event Action<string>? Disconnected;

    /// <summary>
    /// Constructs a <see cref="WaylandConnection"/> with default options and a null logger. Provided
    /// for backwards compatibility with callers that have not to dependency injection yet.
    /// </summary>
    public WaylandConnection()
        : this(NullLogger<WaylandConnection>.Instance, new WaylandOptions())
    {
    }

    /// <summary>
    /// Constructs a <see cref="WaylandConnection"/> with the supplied logger and options.
    /// </summary>
    public WaylandConnection(ILogger<WaylandConnection> logger, WaylandOptions options)
    {
        _logger = logger;
        _options = options;
    }

    public Result Connect()
    {
        if (Display != IntPtr.Zero)
        {
            return Result.Ok;
        }

        var name = _options.DisplayName;
        IntPtr namePtr = IntPtr.Zero;
        try
        {
            if (!string.IsNullOrEmpty(name))
            {
                namePtr = Marshal.StringToCoTaskMemUTF8(name);
            }

            Display = WaylandInterop.wl_display_connect(namePtr);
        }
        finally
        {
            if (namePtr != IntPtr.Zero)
            {
                Marshal.FreeCoTaskMem(namePtr);
            }
        }

        if (Display == IntPtr.Zero)
        {
            var wd = name ?? Environment.GetEnvironmentVariable("WAYLAND_DISPLAY");
            var error = string.IsNullOrEmpty(wd)
                ? "wl_display_connect returned null (WAYLAND_DISPLAY not set)"
                : $"wl_display_connect returned null (WAYLAND_DISPLAY={wd})";
            _logger.LogError("Failed to connect to Wayland display: {Error}", error);
            return Result.Fail(error);
        }

        _logger.LogDebug("Connected to Wayland display (display=0x{Display:x})", Display.ToInt64());
        return Result.Ok;
    }

    public ValueTask<Result> ConnectAsync(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        return new ValueTask<Result>(Connect());
    }

    public int Roundtrip()
    {
        if (Display == IntPtr.Zero)
        {
            return -1;
        }

        var rc = WaylandInterop.wl_display_roundtrip(Display);
        if (_options.VerboseProtocolTrace)
        {
            _logger.LogTrace("wl_display_roundtrip -> {Rc}", rc);
        }
        return rc;
    }

    public int Dispatch()
    {
        if (Display == IntPtr.Zero)
        {
            return -1;
        }

        var rc = WaylandInterop.wl_display_dispatch(Display);
        if (_options.VerboseProtocolTrace)
        {
            _logger.LogTrace("wl_display_dispatch -> {Rc}", rc);
        }
        return rc;
    }

    public int DispatchPending()
    {
        if (Display == IntPtr.Zero)
        {
            return -1;
        }

        // Wl_display_dispatch_pending is not yet exposed by WaylandInterop; fall back to a non-blocking
        // flush+dispatch approximation. When the P/Invoke is added, replace this with the direct call.
        return WaylandInterop.wl_display_dispatch(Display);
    }

    public int Flush()
    {
        if (Display == IntPtr.Zero)
        {
            return -1;
        }

        var rc = WaylandInterop.wl_display_flush(Display);
        if (_options.VerboseProtocolTrace)
        {
            _logger.LogTrace("wl_display_flush -> {Rc}", rc);
        }
        return rc;
    }

    public int GetFd()
    {
        return Display == IntPtr.Zero
            ? -1
            : WaylandInterop.wl_display_get_fd(Display);
    }

    /// <summary>
    /// Closes the connection if one is open. Safe to call multiple times; subsequent calls are no-ops.
    /// Raises <see cref="Disconnected"/> exactly once.
    /// </summary>
    public void Disconnect()
    {
        if (Display != IntPtr.Zero)
        {
            WaylandInterop.wl_display_disconnect(Display);
            Display = IntPtr.Zero;
        }

        if (Interlocked.Exchange(ref _disconnectedRaised, 1) == 0)
        {
            Disconnected?.Invoke("wl_display disconnected");
        }
    }

    public void Dispose() => Disconnect();
}
