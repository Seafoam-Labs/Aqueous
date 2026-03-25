using System.Runtime.InteropServices;
// Opaque struct stubs for types from GObject, GIO, etc.
// These are used as pointer targets in P/Invoke signatures.
#pragma warning disable CS0169 // unused field
// GLib / GIO
public unsafe struct _GObject { private byte _unused; }
public unsafe struct _GList { private byte _unused; }
public unsafe struct _GHashTable { private byte _unused; }
// Wayland
public unsafe struct _wl_registry { private byte _unused; }
public unsafe struct _wl_display { private byte _unused; }
public unsafe struct _wl_output { private byte _unused; }
public unsafe struct _wl_seat { private byte _unused; }
// AstalWl
public unsafe struct _AstalWlRegistryPrivate { private byte _unused; }
public unsafe struct _AstalWlOutputPrivate { private byte _unused; }
public unsafe struct _AstalWlSeatPrivate { private byte _unused; }
#pragma warning restore CS0169
