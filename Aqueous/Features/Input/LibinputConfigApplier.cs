using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River;
using Microsoft.Extensions.Logging;

namespace Aqueous.Features.Input;

/// <summary>
/// Owns the bound <c>river_libinput_config_v1</c> global and pushes <c>[input.*]</c> from
/// <c>wm.toml</c> straight into the compositor's libinput context. Replaces the retired
/// <c>Aqueous.InputDaemon</c> sidecar.
/// <para>
/// Lifecycle: <see cref="OnBound"/> is called once from <c>RiverCompositorHost.HandleRegistryGlobal</c>
/// when the global appears. <see cref="OnDeviceAdded"/>/<see cref="OnDeviceRemoved"/> are called by
/// <c>LibinputConfigEventHandler</c>/<c>LibinputDeviceEventHandler</c> from the libwayland dispatch
/// thread. <see cref="Apply"/> stores the latest <see cref="InputConfig"/> and re-applies to every
/// known device (used on startup and on <c>wm.toml</c> reload).
/// </para>
/// </summary>
internal sealed unsafe class LibinputConfigApplier
{
    private readonly object _lock = new();
    private readonly ConcurrentDictionary<IntPtr, DeviceState> _devices = new();
    private InputConfig _config = InputConfig.Default;
    private static ILogger Log => Logging.Factory.CreateLogger("libinput");

    internal sealed class DeviceState
    {
        /// <summary>Device proxy returned by <c>libinput_device</c> event.</summary>
        public IntPtr Proxy;
        /// <summary>True once <c>tap_support.finger_count &gt; 0</c> was observed — touchpad.</summary>
        public bool IsTouchpad;
        /// <summary>True once a <c>done</c> event arrived; gates the first <c>Apply</c>.</summary>
        public bool DoneSeen;
    }

    /// <summary>
    /// Called from <c>RiverCompositorHost</c> after the global is bound.
    /// </summary>
    public void OnBound()
    {
        Log.LogInformation("river_libinput_config_v1 bound; awaiting devices");
    }

    /// <summary>
    /// Called by <c>LibinputConfigEventHandler</c> when a new device proxy is announced.
    /// </summary>
    public void OnDeviceAdded(IntPtr deviceProxy)
    {
        _devices[deviceProxy] = new DeviceState { Proxy = deviceProxy };
    }

    /// <summary>
    /// Called by <c>LibinputDeviceEventHandler</c> on <c>tap_support</c>.
    /// </summary>
    public void OnTapSupport(IntPtr deviceProxy, int fingerCount)
    {
        if (_devices.TryGetValue(deviceProxy, out var d))
        {
            d.IsTouchpad = fingerCount > 0;
        }
    }

    /// <summary>
    /// Called by <c>LibinputDeviceEventHandler</c> on <c>done</c>. First <c>done</c> triggers an
    /// apply; subsequent <c>done</c>s do too (e.g. after our own <c>set_*</c> requests echo back).
    /// </summary>
    public void OnDeviceDone(IntPtr deviceProxy)
    {
        if (!_devices.TryGetValue(deviceProxy, out var d)) return;
        bool first = !d.DoneSeen;
        d.DoneSeen = true;
        if (first)
        {
            ApplyToDevice(d);
        }
    }

    public void OnDeviceRemoved(IntPtr deviceProxy)
    {
        _devices.TryRemove(deviceProxy, out _);
    }

    /// <summary>
    /// Store a fresh <see cref="InputConfig"/> and re-apply to every known device. Called on
    /// startup and on <c>wm.toml</c> reload.
    /// </summary>
    public void Apply(InputConfig cfg)
    {
        lock (_lock) _config = cfg;
        foreach (var d in _devices.Values)
        {
            if (d.DoneSeen) ApplyToDevice(d);
        }
    }

    private void ApplyToDevice(DeviceState d)
    {
        InputConfig cfg;
        lock (_lock) cfg = _config;
        var per = d.IsTouchpad ? cfg.Touchpad : cfg.Mouse;

        // Accel profile (uint enum).
        string? profile = per.AccelProfile ?? (d.IsTouchpad ? null : (cfg.PointerAcceleration ? "adaptive" : "flat"));
        if (profile is not null)
        {
            uint p = profile.Equals("flat", StringComparison.OrdinalIgnoreCase)
                ? RiverProtocolOpcodes.LibinputAccelProfile.Flat
                : RiverProtocolOpcodes.LibinputAccelProfile.Adaptive;
            SendUintRequest(d.Proxy, RiverProtocolOpcodes.LibinputDeviceRequest.SetAccelProfile, p);
            Log.LogInformation("device 0x{P:x} set_accel_profile={Profile}", d.Proxy.ToInt64(), profile);
        }

        // Accel speed (array<double>).
        double? speed = per.AccelSpeed ?? (d.IsTouchpad ? (double?)null : cfg.PointerAccelerationFactor);
        if (speed is { } sp)
        {
            sp = Math.Clamp(sp, -1.0, 1.0);
            SendDoubleArrayRequest(d.Proxy, RiverProtocolOpcodes.LibinputDeviceRequest.SetAccelSpeed, sp);
            Log.LogInformation("device 0x{P:x} set_accel_speed={Speed}", d.Proxy.ToInt64(), sp);
        }

        if (per.NaturalScroll is { } ns)
        {
            SendUintRequest(d.Proxy, RiverProtocolOpcodes.LibinputDeviceRequest.SetNaturalScroll, ns ? 1u : 0u);
            Log.LogInformation("device 0x{P:x} set_natural_scroll={Ns}", d.Proxy.ToInt64(), ns);
        }

        if (d.IsTouchpad && per.Tap is { } tap)
        {
            SendUintRequest(d.Proxy, RiverProtocolOpcodes.LibinputDeviceRequest.SetTap, tap ? 1u : 0u);
            Log.LogInformation("device 0x{P:x} set_tap={Tap}", d.Proxy.ToInt64(), tap);
        }
    }

    // ---- Wire helpers ------------------------------------------------

    private static void SendUintRequest(IntPtr device, uint opcode, uint value)
    {
        // Every setter has signature "nu": new_id<river_libinput_result_v1>, uint value.
        // wl_proxy_marshal_flags fills the new_id implicitly when iface != null.
        IntPtr result = WaylandInterop.wl_proxy_marshal_flags(
            device, opcode, (IntPtr)WlInterfaces.RiverLibinputResult, 1, 0,
            IntPtr.Zero, (IntPtr)value, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        // We don't install a dispatcher on the result — libwayland will deliver the destructor
        // event and clean up the proxy automatically on our side once it's freed. Any unsupported /
        // invalid replies will be visible via WAYLAND_DEBUG=1; ignoring them is intentional.
        _ = result;
    }

    /// <summary>
    /// Send an "na" request (<c>set_accel_speed</c>) where <c>a</c> is a libwayland
    /// <c>wl_array</c> containing one native-endian IEEE-754 <c>double</c>.
    /// </summary>
    private static void SendDoubleArrayRequest(IntPtr device, uint opcode, double value)
    {
        // Build wl_array { size_t size; size_t alloc; void* data; } pointing at the value.
        // On x86_64 Linux size_t is 8 bytes; struct is 24 bytes.
        IntPtr data = Marshal.AllocHGlobal(sizeof(double));
        try
        {
            Marshal.Copy(new[] { value }, 0, data, 1);
            // Stack-allocated wl_array struct.
            WlArray arr;
            arr.size = (UIntPtr)sizeof(double);
            arr.alloc = (UIntPtr)sizeof(double);
            arr.data = data;
            WaylandInterop.wl_proxy_marshal_flags(
                device, opcode, (IntPtr)WlInterfaces.RiverLibinputResult, 1, 0,
                IntPtr.Zero, (IntPtr)(&arr), IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        }
        finally
        {
            Marshal.FreeHGlobal(data);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WlArray
    {
        public UIntPtr size;
        public UIntPtr alloc;
        public IntPtr data;
    }
}
