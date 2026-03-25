using System.Runtime.InteropServices;

// Opaque struct stubs for types from GObject, GIO, etc.
// These are used as pointer targets in P/Invoke signatures.

#pragma warning disable CS0169 // unused field

// GLib / GIO
public unsafe struct _GObject { private byte _unused; }
public unsafe struct _GObjectClass { private byte _unused; }
public unsafe struct _GTypeInterface { private byte _unused; }
public unsafe struct _GValue { private byte _unused; }
public unsafe struct _GError { private byte _unused; }
public unsafe struct _GList { private byte _unused; }
public unsafe struct _GAppInfo { private byte _unused; }
public unsafe struct _GDesktopAppInfo { private byte _unused; }

// AstalApps
public unsafe struct _AstalAppsApplication { private byte _unused; }
public unsafe struct _AstalAppsApplicationClass { private byte _unused; }
public unsafe struct _AstalAppsApps { private byte _unused; }
public unsafe struct _AstalAppsAppsClass { private byte _unused; }

[StructLayout(LayoutKind.Sequential)]
public struct _AstalAppsScore
{
    [NativeTypeName("gint")]
    public int name;
    [NativeTypeName("gint")]
    public int entry;
    [NativeTypeName("gint")]
    public int executable;
    [NativeTypeName("gint")]
    public int description;
    [NativeTypeName("gint")]
    public int keywords;
    [NativeTypeName("gint")]
    public int categories;
}

#pragma warning restore CS0169
