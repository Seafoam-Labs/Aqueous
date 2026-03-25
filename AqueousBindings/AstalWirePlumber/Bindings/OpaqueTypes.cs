using System.Runtime.InteropServices;

// Opaque struct stubs for types from GObject, GIO, etc.
// These are used as pointer targets in P/Invoke signatures.
#pragma warning disable CS0169 // unused field

// GLib / GIO
public unsafe struct _GObject { private byte _unused; }
public unsafe struct _GError { private byte _unused; }
public unsafe struct _GList { private byte _unused; }

// AstalWirePlumber
public unsafe struct _AstalWpWpPrivate { private byte _unused; }
public unsafe struct _AstalWpAudioPrivate { private byte _unused; }
public unsafe struct _AstalWpVideoPrivate { private byte _unused; }
public unsafe struct _AstalWpNodePrivate { private byte _unused; }
public unsafe struct _AstalWpEndpointPrivate { private byte _unused; }
public unsafe struct _AstalWpStreamPrivate { private byte _unused; }
public unsafe struct _AstalWpDevicePrivate { private byte _unused; }
public unsafe struct _AstalWpProfilePrivate { private byte _unused; }
public unsafe struct _AstalWpRoutePrivate { private byte _unused; }
public unsafe struct _AstalWpChannelPrivate { private byte _unused; }

#pragma warning restore CS0169
