using System;
using System.Diagnostics;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Custom-action runner partial of <see cref="RiverWindowManagerClient"/>:
/// dispatches the free-form <c>spawn:</c>/<c>set_layout:</c>/<c>builtin:</c>
/// verbs that <c>[keybinds.custom]</c> entries can attach to any chord, and
/// owns the shell-escape helper. Built-in verbs route through
/// <see cref="BuiltinActionMap"/> (declared in
/// <c>RiverWindowManagerClient.KeyBindingRegistrar.cs</c>) to reach the
/// router's <c>InvokeBuiltin</c>.
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient
{
    /// <summary>
    /// Dispatch a custom action verb. Recognised forms:
    /// <list type="bullet">
    ///   <item><c>spawn:&lt;cmd&gt;</c> — fork/exec via <c>/bin/sh -c</c>.</item>
    ///   <item><c>set_layout:&lt;id-or-slot&gt;</c> — switch active layout.</item>
    ///   <item><c>builtin:&lt;action_name&gt;</c> — invoke a built-in.</item>
    /// </list>
    /// </summary>
    private void RunCustomAction(string action)
    {
        int colon = action.IndexOf(':');
        string verb = colon < 0 ? action : action.Substring(0, colon);
        string arg = colon < 0 ? "" : action.Substring(colon + 1).Trim();
        switch (verb)
        {
            case "spawn":
                RunSpawnVerb(arg);
                break;
            case "set_layout":
                SetLayoutByIdOrSlot(arg);
                break;
            case "builtin":
                RunBuiltinVerb(arg);
                break;
            default:
                Log($"unknown custom action verb '{verb}'");
                break;
        }
    }

    private void RunSpawnVerb(string arg)
    {
        if (arg.Length == 0)
        {
            return;
        }

        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "/bin/sh",
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            psi.ArgumentList.Add("-c");
            psi.ArgumentList.Add($"setsid -f sh -c {EscapeForShell(arg)} >/dev/null 2>&1");
            var wayland = Environment.GetEnvironmentVariable("WAYLAND_DISPLAY");
            var runtime = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
            if (!string.IsNullOrEmpty(wayland))
            {
                psi.EnvironmentVariables["WAYLAND_DISPLAY"] = wayland;
            }

            if (!string.IsNullOrEmpty(runtime))
            {
                psi.EnvironmentVariables["XDG_RUNTIME_DIR"] = runtime;
            }

            psi.EnvironmentVariables.Remove("DISPLAY");
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            Log($"spawn '{arg}' failed: {ex.Message}");
        }
    }

    private void RunBuiltinVerb(string arg)
    {
        // Phase B1e Pass B: split one optional trailing ":argument"
        // segment so chords like
        //   builtin:toggle_scratchpad_named:term
        // can dispatch to the parameterised actions while preserving
        // the existing parameterless form (e.g. builtin:cycle_focus).
        string bname = arg;
        string barg = string.Empty;
        int sub = arg.IndexOf(':');
        if (sub >= 0)
        {
            bname = arg.Substring(0, sub);
            barg = arg.Substring(sub + 1).Trim();
        }

        switch (bname)
        {
            case "toggle_scratchpad_named":
                if (barg.Length == 0)
                {
                    Log("builtin:toggle_scratchpad_named requires :name");
                    return;
                }

                _windowState.ToggleScratchpad(barg);
                return;
            case "send_to_scratchpad_named":
                if (barg.Length == 0)
                {
                    Log("builtin:send_to_scratchpad_named requires :name");
                    return;
                }

                if (_focusedWindow != IntPtr.Zero)
                {
                    _windowState.SendToScratchpad(_focusedWindow, barg);
                }
                else
                {
                    Log("builtin:send_to_scratchpad_named: no focused window");
                }

                return;
            default:
                if (BuiltinActionMap.TryGetValue(bname, out var b))
                {
                    InvokeBuiltin(b);
                }
                else
                {
                    Log($"unknown builtin '{bname}'");
                }

                return;
        }
    }

    private static string EscapeForShell(string s) => "'" + s.Replace("'", "'\\''") + "'";
}
