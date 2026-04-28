using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using static Aqueous.InputDaemon.LibinputInterop;

namespace Aqueous.InputDaemon;

/// <summary>
/// <c>aqueous-inputd</c> — privileged libinput sidecar for Aqueous.
/// <para>
/// Owns its own libinput context (via <c>libinput_udev_create_context</c>)
/// and applies per-device configuration in response to <c>apply</c>
/// requests received over <c>$XDG_RUNTIME_DIR/aqueous-inputd.sock</c>.
/// Mirrors niri's in-process model — applies on <c>DEVICE_ADDED</c> and
/// re-applies to all currently-open devices on every <c>apply</c>.
/// </para>
/// <para>
/// Privilege model: <c>open_restricted</c> uses plain <c>open(O_RDWR)</c>;
/// the daemon must therefore run as a user in the <c>input</c> group (or
/// as root). A <c>logind</c> <c>TakeDevice</c> path is the future
/// follow-up so the daemon can run as the regular user.
/// </para>
/// </summary>
internal static class Program
{
    private static readonly object _lock = new();
    private static PerDevice _mouse      = new();
    private static PerDevice _touchpad   = new();
    private static PerDevice _trackpoint = new();
    private static readonly List<IntPtr> _openDevices = new();

    private static unsafe int Main(string[] args)
    {
        Log("starting aqueous-inputd");

        // Pin libinput interface vtable for the lifetime of the process.
        delegate* unmanaged[Cdecl]<IntPtr, int, IntPtr, int>     openCb  = &OpenRestricted;
        delegate* unmanaged[Cdecl]<int, IntPtr, void>            closeCb = &CloseRestricted;
        var vtable = new LibinputInterfaceVTable
        {
            open_restricted  = (IntPtr)openCb,
            close_restricted = (IntPtr)closeCb,
        };

        IntPtr udev = udev_new();
        if (udev == IntPtr.Zero) { Log("udev_new failed"); return 2; }

        IntPtr li = libinput_udev_create_context(&vtable, IntPtr.Zero, udev);
        if (li == IntPtr.Zero) { Log("libinput_udev_create_context failed"); return 3; }

        if (libinput_udev_assign_seat(li, "seat0") != 0)
        {
            Log("libinput_udev_assign_seat(seat0) failed (need input group / logind?)");
            return 4;
        }

        var sockPath = SocketPath();
        try { File.Delete(sockPath); } catch { }
        var listener = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        listener.Bind(new UnixDomainSocketEndPoint(sockPath));
        listener.Listen(8);
        try { File.SetUnixFileMode(sockPath, UnixFileMode.UserRead | UnixFileMode.UserWrite); } catch { }
        Log($"listening on {sockPath}");

        // Accept loop on a worker; libinput pump on the main thread.
        var cts = new CancellationTokenSource();
        Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };
        _ = Task.Run(() => AcceptLoop(listener, li, cts.Token));

        // libinput pump: drain events synchronously. We don't actually
        // need to wait on the fd for config-apply work — every apply
        // walks the cached _openDevices list. But we still need to
        // dispatch so DEVICE_ADDED events are delivered.
        var pollFd = libinput_get_fd(li);
        Log($"libinput fd={pollFd}");
        // Initial dispatch so any already-present devices show up.
        libinput_dispatch(li);
        DrainEvents(li);

        var pfd = new PollFd { fd = pollFd, events = PollIn };
        while (!cts.IsCancellationRequested)
        {
            int r = poll(&pfd, 1, 1000);
            if (r < 0) break;
            if (r == 0) continue;
            libinput_dispatch(li);
            DrainEvents(li);
        }

        Log("shutting down");
        listener.Close();
        try { File.Delete(sockPath); } catch { }
        libinput_unref(li);
        udev_unref(udev);
        return 0;
    }

    // ----- libinput interface callbacks (unmanaged) ---------------------

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(System.Runtime.CompilerServices.CallConvCdecl) })]
    private static int OpenRestricted(IntPtr pathPtr, int flags, IntPtr userData)
    {
        var path = PtrToString(pathPtr);
        if (path is null) return -1;
        int fd = open(path, flags);
        if (fd < 0)
        {
            // Surface a hint to stderr; libinput will treat <0 as failure.
            Console.Error.WriteLine($"[aqueous-inputd] open({path}) failed errno={Marshal.GetLastWin32Error()} — is the daemon user in the 'input' group?");
            return -1;
        }
        return fd;
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(System.Runtime.CompilerServices.CallConvCdecl) })]
    private static void CloseRestricted(int fd, IntPtr userData)
    {
        close(fd);
    }

    // ----- event drain --------------------------------------------------

    private static void DrainEvents(IntPtr li)
    {
        while (true)
        {
            var ev = libinput_get_event(li);
            if (ev == IntPtr.Zero) return;
            int type = libinput_event_get_type(ev);
            if (type == LIBINPUT_EVENT_DEVICE_ADDED)
            {
                var dev = libinput_event_get_device(ev);
                lock (_lock) { if (!_openDevices.Contains(dev)) _openDevices.Add(dev); }
                ApplyToDevice(dev);
            }
            else if (type == LIBINPUT_EVENT_DEVICE_REMOVED)
            {
                var dev = libinput_event_get_device(ev);
                lock (_lock) _openDevices.Remove(dev);
            }
            libinput_event_destroy(ev);
        }
    }

    // ----- device classification + apply -------------------------------

    private enum Kind { Mouse, Touchpad, Trackpoint }

    private static Kind Classify(IntPtr dev)
    {
        var name = PtrToString(libinput_device_get_name(dev)) ?? "";
        // Touchpads expose tap finger count > 0; libinput's only reliable
        // touchpad signal short of udev properties.
        if (libinput_device_config_tap_get_finger_count(dev) > 0) return Kind.Touchpad;
        // Trackpoint identification is name-based; libinput has no flag.
        var lower = name.ToLowerInvariant();
        if (lower.Contains("trackpoint") || lower.Contains("track point") || lower.Contains("pointing stick"))
            return Kind.Trackpoint;
        return Kind.Mouse;
    }

    private static void ApplyToDevice(IntPtr dev)
    {
        if (libinput_device_has_capability(dev, DeviceCapability.Pointer) == 0) return;

        PerDevice cfg;
        Kind kind = Classify(dev);
        lock (_lock)
        {
            cfg = kind switch
            {
                Kind.Touchpad   => _touchpad,
                Kind.Trackpoint => _trackpoint,
                _               => _mouse,
            };
        }
        var name = PtrToString(libinput_device_get_name(dev)) ?? "?";
        Log($"applying {kind} cfg to '{name}': profile={cfg.AccelProfile ?? "-"} speed={cfg.AccelSpeed?.ToString() ?? "-"}");

        if (cfg.AccelProfile is { } p && libinput_device_config_accel_is_available(dev) != 0)
        {
            var profile = p.Equals("flat", StringComparison.OrdinalIgnoreCase)
                ? AccelProfile.Flat : AccelProfile.Adaptive;
            libinput_device_config_accel_set_profile(dev, profile);
        }
        if (cfg.AccelSpeed is { } sp && libinput_device_config_accel_is_available(dev) != 0)
        {
            libinput_device_config_accel_set_speed(dev, Math.Clamp(sp, -1.0, 1.0));
        }
        if (cfg.NaturalScroll is { } ns && libinput_device_config_scroll_has_natural_scroll(dev) != 0)
        {
            libinput_device_config_scroll_set_natural_scroll_enabled(dev, ns ? 1 : 0);
        }
        if (cfg.Tap is { } tap && libinput_device_config_tap_get_finger_count(dev) > 0)
        {
            libinput_device_config_tap_set_enabled(dev, tap ? 1 : 0);
        }
        if (cfg.Dwt is { } dwt && libinput_device_config_dwt_is_available(dev) != 0)
        {
            libinput_device_config_dwt_set_enabled(dev, dwt ? 1 : 0);
        }
        if (cfg.LeftHanded is { } lh && libinput_device_config_left_handed_is_available(dev) != 0)
        {
            libinput_device_config_left_handed_set(dev, lh ? 1 : 0);
        }
        if (cfg.MiddleEmulation is { } me && libinput_device_config_middle_emulation_is_available(dev) != 0)
        {
            libinput_device_config_middle_emulation_set_enabled(dev, me ? 1 : 0);
        }
        if (cfg.ClickMethod is { } cm)
        {
            uint avail = libinput_device_config_click_get_methods(dev);
            ClickMethod want = cm switch
            {
                "clickfinger"  => ClickMethod.Clickfinger,
                "button-areas" or "button_areas" => ClickMethod.ButtonAreas,
                _ => ClickMethod.None,
            };
            if (want != ClickMethod.None && (avail & (uint)want) != 0)
                libinput_device_config_click_set_method(dev, want);
        }
        if (cfg.ScrollMethod is { } sm)
        {
            uint avail = libinput_device_config_scroll_get_methods(dev);
            ScrollMethod want = sm switch
            {
                "two-finger" or "two_finger" => ScrollMethod.TwoFinger,
                "edge"                       => ScrollMethod.Edge,
                "no-scroll" or "no_scroll"   => ScrollMethod.NoScroll,
                _                            => ScrollMethod.NoScroll,
            };
            if (want == ScrollMethod.NoScroll || (avail & (uint)want) != 0)
                libinput_device_config_scroll_set_method(dev, want);
        }
    }

    private static void ReapplyAll()
    {
        IntPtr[] snap;
        lock (_lock) snap = _openDevices.ToArray();
        foreach (var d in snap) ApplyToDevice(d);
    }

    // ----- UDS server ---------------------------------------------------

    private static async Task AcceptLoop(Socket listener, IntPtr li, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            Socket client;
            try { client = await listener.AcceptAsync(ct); }
            catch { return; }
            _ = Task.Run(() => HandleClient(client, ct));
        }
    }

    private static async Task HandleClient(Socket client, CancellationToken ct)
    {
        try
        {
            using var _ = client;
            var buf = new byte[8192];
            int read = await client.ReceiveAsync(buf, SocketFlags.None, ct);
            if (read <= 0) return;
            var line = Encoding.UTF8.GetString(buf, 0, read);
            int nl = line.IndexOf('\n');
            if (nl >= 0) line = line.Substring(0, nl);
            var obj = JsonReader.ParseObject(line);
            if (obj is null)
            {
                await client.SendAsync(Encoding.UTF8.GetBytes("{\"ok\":false,\"err\":\"bad json\"}\n"), SocketFlags.None);
                return;
            }
            string? kind = obj.TryGetValue("kind", out var k) ? k as string : null;
            if (kind == "apply")
            {
                lock (_lock)
                {
                    _mouse      = ParsePerDevice(obj, "mouse")      ?? _mouse;
                    _touchpad   = ParsePerDevice(obj, "touchpad")   ?? _touchpad;
                    _trackpoint = ParsePerDevice(obj, "trackpoint") ?? _trackpoint;
                }
                ReapplyAll();
                await client.SendAsync(Encoding.UTF8.GetBytes("{\"ok\":true}\n"), SocketFlags.None);
            }
            else
            {
                await client.SendAsync(Encoding.UTF8.GetBytes("{\"ok\":false,\"err\":\"unknown kind\"}\n"), SocketFlags.None);
            }
        }
        catch (Exception ex)
        {
            Log("client error: " + ex.Message);
        }
    }

    private static PerDevice? ParsePerDevice(Dictionary<string, object?> root, string key)
    {
        if (!root.TryGetValue(key, out var v) || v is not Dictionary<string, object?> d) return null;
        return new PerDevice
        {
            AccelProfile    = d.GetValueOrDefault("accel_profile") as string,
            AccelSpeed      = d.GetValueOrDefault("accel_speed") is double s ? s : null,
            NaturalScroll   = d.GetValueOrDefault("natural_scroll") as bool?,
            Tap             = d.GetValueOrDefault("tap") as bool?,
            Dwt             = d.GetValueOrDefault("dwt") as bool?,
            LeftHanded      = d.GetValueOrDefault("left_handed") as bool?,
            ClickMethod     = d.GetValueOrDefault("click_method") as string,
            ScrollMethod    = d.GetValueOrDefault("scroll_method") as string,
            MiddleEmulation = d.GetValueOrDefault("middle_emulation") as bool?,
        };
    }

    // ----- helpers ------------------------------------------------------

    private sealed class PerDevice
    {
        public string? AccelProfile;
        public double? AccelSpeed;
        public bool?   NaturalScroll;
        public bool?   Tap;
        public bool?   Dwt;
        public bool?   LeftHanded;
        public string? ClickMethod;
        public string? ScrollMethod;
        public bool?   MiddleEmulation;
    }

    private static string SocketPath()
    {
        var rt = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
        if (string.IsNullOrEmpty(rt)) rt = "/tmp";
        return Path.Combine(rt, "aqueous-inputd.sock");
    }

    private static void Log(string msg) =>
        Console.WriteLine($"[aqueous-inputd] {msg}");

    // ----- poll(2) ------------------------------------------------------

    [StructLayout(LayoutKind.Sequential)]
    private struct PollFd
    {
        public int fd;
        public short events;
        public short revents;
    }
    private const short PollIn = 0x0001;

    [DllImport("libc", SetLastError = true)]
    private static extern unsafe int poll(PollFd* fds, uint nfds, int timeoutMs);
}
