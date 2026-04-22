using System;
using System.IO;

namespace Aqueous.Helpers;

/// <summary>
/// Resolves and caches the Wayfire IPC socket path. The path is stable for a session, so we
/// resolve once and reuse — previous code re-enumerated <c>$XDG_RUNTIME_DIR</c> / <c>/tmp</c>
/// on every IPC call. Callers should invoke <see cref="Invalidate"/> on connect failure so the
/// next call re-resolves (handles compositor restart within the same session).
/// </summary>
public static class WayfireSocket
{
    private static string? _cached;
    private static readonly object Sync = new();

    public static string Resolve()
    {
        var cached = _cached;
        if (cached != null) return cached;

        lock (Sync)
        {
            if (_cached != null) return _cached;

            var envPath = Environment.GetEnvironmentVariable("WAYFIRE_SOCKET")
                          ?? Environment.GetEnvironmentVariable("_WAYFIRE_SOCKET");
            if (!string.IsNullOrEmpty(envPath))
            {
                _cached = envPath;
                return _cached;
            }

            var runtimeDir = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
            if (!string.IsNullOrEmpty(runtimeDir) && Directory.Exists(runtimeDir))
            {
                var files = Directory.GetFiles(runtimeDir, "wayfire-*.socket");
                if (files.Length > 0) { _cached = files[0]; return _cached; }
            }

            var tmpFiles = Directory.GetFiles("/tmp", "wayfire-*.socket");
            if (tmpFiles.Length > 0) { _cached = tmpFiles[0]; return _cached; }

            throw new FileNotFoundException(
                "No Wayfire IPC socket found. Ensure 'ipc' plugin is enabled and WAYFIRE_SOCKET is set.");
        }
    }

    public static void Invalidate()
    {
        lock (Sync) _cached = null;
    }
}
