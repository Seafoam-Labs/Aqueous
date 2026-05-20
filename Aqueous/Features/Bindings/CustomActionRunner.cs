using System;
using System.Diagnostics;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.State;

namespace Aqueous.Features.Bindings;

/// <summary>
/// PR 9.9 (Stage 9): top-level <see cref="ICustomActionRunner"/> implementation.
///
/// Lifted verbatim from the deleted partial
/// <c>RiverWindowManagerClient.CustomActionRunner.cs</c>: dispatches the free-form
/// <c>spawn:</c>/<c>set_layout:</c>/<c>builtin:</c> verbs that <c>[keybinds.custom]</c>
/// entries can attach to any chord, and owns the shell-escape helper. Built-in verbs
/// resolve through the registrar-owned <see cref="RiverWindowManagerClient.BuiltinActionMap"/>
/// and re-enter the top-level <see cref="KeyBindingRouter"/>.
/// </summary>
internal sealed class CustomActionRunner : ICustomActionRunner
{
    private readonly RiverWindowManagerClient _river;

    public CustomActionRunner(RiverWindowManagerClient river)
    {
        _river = river ?? throw new ArgumentNullException(nameof(river));
    }

    /// <summary>
    /// Dispatch a custom action verb. Recognised forms:
    /// <list type="bullet">
    ///   <item><c>spawn:&lt;cmd&gt;</c> — fork/exec via <c>/bin/sh -c</c>.</item>
    ///   <item><c>set_layout:&lt;id-or-slot&gt;</c> — switch active layout.</item>
    ///   <item><c>builtin:&lt;action_name&gt;</c> — invoke a built-in.</item>
    /// </list>
    /// </summary>
    public void Run(string verb)
    {
        if (verb is null) return;

        int colon = verb.IndexOf(':');
        string head = colon < 0 ? verb : verb.Substring(0, colon);
        string arg = colon < 0 ? "" : verb.Substring(colon + 1).Trim();
        switch (head)
        {
            case "spawn":
                RunSpawnVerb(arg);
                break;
            case "set_layout":
                Router().SetLayoutByIdOrSlot(arg);
                break;
            case "builtin":
                RunBuiltinVerb(arg);
                break;
            default:
                _river.LogForwarding($"unknown custom action verb '{head}'");
                break;
        }
    }

    /// <summary>
    /// Resolve the concrete <see cref="KeyBindingRouter"/> from the god-class
    /// accessor; downcast is safe because the DI registration constructs
    /// exactly one router instance, of this concrete type.
    /// </summary>
    private KeyBindingRouter Router()
    {
        return (KeyBindingRouter)_river.KeyBindingRouterForCustom;
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
            _river.LogForwarding($"spawn '{arg}' failed: {ex.Message}");
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
                    _river.LogForwarding("builtin:toggle_scratchpad_named requires :name");
                    return;
                }

                _river.WindowStateController.ToggleScratchpad(barg);
                return;
            case "send_to_scratchpad_named":
                if (barg.Length == 0)
                {
                    _river.LogForwarding("builtin:send_to_scratchpad_named requires :name");
                    return;
                }

                if (_river.FocusServiceForBindings.TryGetFocusedAlive(out var focusedForScratchpad))
                {
                    _river.WindowStateController.SendToScratchpad(new WindowProxy(focusedForScratchpad), barg);
                }
                else
                {
                    _river.LogForwarding("builtin:send_to_scratchpad_named: no focused window");
                }

                return;
            default:
                if (RiverWindowManagerClient.BuiltinActionMap.TryGetValue(bname, out var b))
                {
                    Router().InvokeBuiltin(b);
                }
                else
                {
                    _river.LogForwarding($"unknown builtin '{bname}'");
                }

                return;
        }
    }

    private static string EscapeForShell(string s) => "'" + s.Replace("'", "'\\''") + "'";
}
