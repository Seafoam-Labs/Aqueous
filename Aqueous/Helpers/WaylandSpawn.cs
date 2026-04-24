using System;
using System.Diagnostics;

namespace Aqueous.Helpers;

/// <summary>
/// Centralised helper for launching external applications from the Aqueous
/// shell. Ensures child processes:
///   * Detach from the shell process (via <c>setsid -f</c>) so they survive
///     shell restarts / respawns and live in their own session.
///   * See the same <c>WAYLAND_DISPLAY</c> / <c>XDG_RUNTIME_DIR</c> that the
///     shell is using, so they register as native Wayland clients with the
///     compositor (river) and get a proper <c>river_window_v1</c>.
///   * Do NOT inherit <c>DISPLAY</c>, which would otherwise cause silent
///     Xwayland fallback — the resulting X11 surface never appears as a
///     river window and therefore never receives keyboard / pointer focus.
///
/// This is the same hardened path used by the WM's built-in spawn keybinding
/// (<c>RiverWindowManagerClient.SpawnTerminal</c>). Using it everywhere fixes
/// the "spawning from Aqueous start menu doesn't get focus / input" bug.
/// </summary>
public static class WaylandSpawn
{
    /// <summary>
    /// Launch <paramref name="execLine"/> (a shell-parseable command, e.g. the
    /// already-field-code-stripped <c>Exec=</c> value from a .desktop file) as
    /// a detached Wayland client.
    /// </summary>
    /// <returns>true on success, false if Process.Start threw.</returns>
    public static bool Spawn(string execLine)
    {
        if (string.IsNullOrWhiteSpace(execLine)) return false;
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "/bin/sh",
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            psi.ArgumentList.Add("-c");
            // setsid -f: start in a new session and fork so the child is
            // reparented to init (PID 1) and cannot be killed when our
            // process exits or the shell's GTK main loop tears down.
            psi.ArgumentList.Add($"setsid -f {execLine} >/dev/null 2>&1");

            ApplyWaylandEnvironment(psi);

            Process.Start(psi);
            return true;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[WaylandSpawn] failed to launch '{execLine}': {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Ensure the child process's environment is explicitly Wayland-first and
    /// has no stale X11 fallback variables. Safe to call on any
    /// <see cref="ProcessStartInfo"/> before <see cref="Process.Start(ProcessStartInfo)"/>.
    /// </summary>
    public static void ApplyWaylandEnvironment(ProcessStartInfo psi)
    {
        var wayland = Environment.GetEnvironmentVariable("WAYLAND_DISPLAY");
        var runtime = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");

        if (!string.IsNullOrEmpty(wayland))
            psi.EnvironmentVariables["WAYLAND_DISPLAY"] = wayland;
        if (!string.IsNullOrEmpty(runtime))
            psi.EnvironmentVariables["XDG_RUNTIME_DIR"] = runtime;

        psi.EnvironmentVariables["XDG_SESSION_TYPE"] = "wayland";
        psi.EnvironmentVariables["XDG_CURRENT_DESKTOP"] = "Aqueous";

        // Critical: remove DISPLAY so toolkits (GTK/Qt/SDL/etc.) don't
        // silently pick the Xwayland backend instead of native Wayland.
        psi.EnvironmentVariables.Remove("DISPLAY");
    }
}
