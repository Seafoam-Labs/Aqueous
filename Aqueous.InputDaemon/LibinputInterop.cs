using System;
using System.Runtime.InteropServices;

namespace Aqueous.InputDaemon;

/// <summary>
/// P/Invoke surface for libinput / libudev. Covers only the calls
/// <c>aqueous-inputd</c> needs: udev context, libinput context creation,
/// device enumeration, capability checks, and the
/// <c>libinput_device_config_*</c> setters that mirror niri's KDL
/// <c>input { mouse|touchpad|trackpoint { … } }</c> blocks.
/// </summary>
internal static unsafe class LibinputInterop
{
    private const string Libinput = "libinput.so.10";
    private const string Libudev  = "libudev.so.1";

    // ----- libudev ------------------------------------------------------

    [DllImport(Libudev)] public static extern IntPtr udev_new();
    [DllImport(Libudev)] public static extern IntPtr udev_unref(IntPtr udev);

    // ----- libinput interface vtable ------------------------------------

    /// <summary>
    /// libinput_interface — open_restricted / close_restricted callbacks.
    /// Marshalled by-pointer to libinput_udev_create_context.
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct LibinputInterfaceVTable
    {
        public IntPtr open_restricted;   // int (*)(const char *path, int flags, void *user_data)
        public IntPtr close_restricted;  // void (*)(int fd, void *user_data)
    }

    // ----- libinput context ---------------------------------------------

    [DllImport(Libinput)]
    public static extern IntPtr libinput_udev_create_context(
        LibinputInterfaceVTable* vtable, IntPtr userData, IntPtr udev);

    [DllImport(Libinput, CharSet = CharSet.Ansi)]
    public static extern int libinput_udev_assign_seat(IntPtr li, string seatId);

    [DllImport(Libinput)] public static extern IntPtr libinput_unref(IntPtr li);
    [DllImport(Libinput)] public static extern int    libinput_get_fd(IntPtr li);
    [DllImport(Libinput)] public static extern int    libinput_dispatch(IntPtr li);
    [DllImport(Libinput)] public static extern IntPtr libinput_get_event(IntPtr li);

    // ----- libinput events ----------------------------------------------

    public const int LIBINPUT_EVENT_DEVICE_ADDED   = 1;
    public const int LIBINPUT_EVENT_DEVICE_REMOVED = 2;

    [DllImport(Libinput)] public static extern int    libinput_event_get_type(IntPtr ev);
    [DllImport(Libinput)] public static extern IntPtr libinput_event_get_device(IntPtr ev);
    [DllImport(Libinput)] public static extern void   libinput_event_destroy(IntPtr ev);

    // ----- libinput devices ---------------------------------------------

    [Flags]
    public enum DeviceCapability
    {
        Keyboard      = 0,
        Pointer       = 1,
        Touch         = 2,
        TabletTool    = 3,
        TabletPad     = 4,
        Gesture       = 5,
        Switch        = 6,
    }

    [DllImport(Libinput)]
    public static extern int libinput_device_has_capability(IntPtr dev, DeviceCapability cap);

    [DllImport(Libinput)] public static extern IntPtr libinput_device_get_name(IntPtr dev);

    // ----- accel --------------------------------------------------------

    public enum AccelProfile : uint
    {
        None     = 0,
        Flat     = 1u << 0,
        Adaptive = 1u << 1,
        Custom   = 1u << 2,
    }

    public enum ConfigStatus
    {
        Success         = 0,
        Unsupported     = 1,
        InvalidArgument = 2,
    }

    [DllImport(Libinput)] public static extern uint  libinput_device_config_accel_get_profiles(IntPtr dev);
    [DllImport(Libinput)] public static extern int   libinput_device_config_accel_set_profile(IntPtr dev, AccelProfile profile);
    [DllImport(Libinput)] public static extern int   libinput_device_config_accel_set_speed(IntPtr dev, double speed);
    [DllImport(Libinput)] public static extern int   libinput_device_config_accel_is_available(IntPtr dev);

    // ----- tap / dwt / scroll / left-handed / middle ---------------------

    [DllImport(Libinput)] public static extern int libinput_device_config_tap_get_finger_count(IntPtr dev);
    [DllImport(Libinput)] public static extern int libinput_device_config_tap_set_enabled(IntPtr dev, int enabled);

    [DllImport(Libinput)] public static extern int libinput_device_config_dwt_is_available(IntPtr dev);
    [DllImport(Libinput)] public static extern int libinput_device_config_dwt_set_enabled(IntPtr dev, int enabled);

    [DllImport(Libinput)] public static extern int libinput_device_config_scroll_has_natural_scroll(IntPtr dev);
    [DllImport(Libinput)] public static extern int libinput_device_config_scroll_set_natural_scroll_enabled(IntPtr dev, int enabled);

    [DllImport(Libinput)] public static extern int libinput_device_config_left_handed_is_available(IntPtr dev);
    [DllImport(Libinput)] public static extern int libinput_device_config_left_handed_set(IntPtr dev, int enabled);

    [DllImport(Libinput)] public static extern int libinput_device_config_middle_emulation_is_available(IntPtr dev);
    [DllImport(Libinput)] public static extern int libinput_device_config_middle_emulation_set_enabled(IntPtr dev, int enabled);

    // click_method bitmask
    public enum ClickMethod : uint
    {
        None          = 0,
        ButtonAreas   = 1u << 0,
        Clickfinger   = 1u << 1,
    }
    [DllImport(Libinput)] public static extern uint libinput_device_config_click_get_methods(IntPtr dev);
    [DllImport(Libinput)] public static extern int  libinput_device_config_click_set_method(IntPtr dev, ClickMethod method);

    // scroll_method bitmask
    public enum ScrollMethod : uint
    {
        NoScroll      = 0,
        TwoFinger     = 1u << 0,
        Edge          = 1u << 1,
        OnButtonDown  = 1u << 2,
    }
    [DllImport(Libinput)] public static extern uint libinput_device_config_scroll_get_methods(IntPtr dev);
    [DllImport(Libinput)] public static extern int  libinput_device_config_scroll_set_method(IntPtr dev, ScrollMethod method);

    // ----- libc ----------------------------------------------------------

    [DllImport("libc", SetLastError = true, CharSet = CharSet.Ansi)]
    public static extern int open(string path, int flags);

    [DllImport("libc")]
    public static extern int close(int fd);

    public const int O_RDWR     = 2;
    public const int O_NONBLOCK = 2048;

    public static string? PtrToString(IntPtr p) =>
        p == IntPtr.Zero ? null : Marshal.PtrToStringAnsi(p);
}
