using System;
using System.Diagnostics;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Focus;
using Aqueous.Features.State;

namespace Aqueous.Features.Bindings;

/// <summary>
/// PR 9.9 (Stage 9): top-level <see cref="ICustomActionRunner"/> implementation.
///
/// PR 9.12 §2.6: ctor converted from a single <see cref="RiverWindowManagerClient"/>
/// reference to fine-grained service injection. The runner still holds a thin
/// <see cref="RiverWindowManagerClient"/> reference for the cross-cutting
/// helpers that remain on the god class (<c>LogForwarding</c>) and for access
/// to the registrar's <c>BuiltinActionMap</c> (still living on a god-class
/// partial). Those retire naturally in §2.7 / §2.13.
/// </summary>
internal sealed class CustomActionRunner : ICustomActionRunner
{
    private readonly IKeyBindingRouter _router;
    private readonly IFocusService _focusService;
    private readonly WindowStateController _windowState;
    private readonly RiverWindowManagerClient _river;

    public CustomActionRunner(
        IKeyBindingRouter router,
        IFocusService focusService,
        WindowStateController windowState,
        RiverWindowManagerClient river)
    {
        _router = router ?? throw new ArgumentNullException(nameof(router));
        _focusService = focusService ?? throw new ArgumentNullException(nameof(focusService));
        _windowState = windowState ?? throw new ArgumentNullException(nameof(windowState));
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
                ConcreteRouter().SetLayoutByIdOrSlot(arg);
                break;
            case "builtin":
                RunBuiltinVerb(arg);
                break;
            default:
                Aqueous.Features.Compositor.River.RiverWindowManagerClient.Log($"unknown custom action verb '{head}'");
                break;
        }
    }

    /// <summary>
    /// Downcast the DI-injected <see cref="IKeyBindingRouter"/> to the concrete
    /// <see cref="KeyBindingRouter"/> for the two entry points custom verbs
    /// reach that aren't on the interface (<c>SetLayoutByIdOrSlot</c>,
    /// <c>InvokeBuiltin</c>). Safe because DI only registers exactly one
    /// router instance of this concrete type.
    /// </summary>
    private KeyBindingRouter ConcreteRouter() => (KeyBindingRouter)_router;

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
            Aqueous.Features.Compositor.River.RiverWindowManagerClient.Log($"spawn '{arg}' failed: {ex.Message}");
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
                    Aqueous.Features.Compositor.River.RiverWindowManagerClient.Log("builtin:toggle_scratchpad_named requires :name");
                    return;
                }

                _windowState.ToggleScratchpad(barg);
                return;
            case "send_to_scratchpad_named":
                if (barg.Length == 0)
                {
                    Aqueous.Features.Compositor.River.RiverWindowManagerClient.Log("builtin:send_to_scratchpad_named requires :name");
                    return;
                }

                if (_focusService.TryGetFocusedAlive(out var focusedForScratchpad))
                {
                    _windowState.SendToScratchpad(new WindowProxy(focusedForScratchpad), barg);
                }
                else
                {
                    Aqueous.Features.Compositor.River.RiverWindowManagerClient.Log("builtin:send_to_scratchpad_named: no focused window");
                }

                return;
            default:
                if (KeyBindingActionTable.Map.TryGetValue(bname, out var b))
                {
                    ConcreteRouter().InvokeBuiltin(b);
                }
                else
                {
                    Aqueous.Features.Compositor.River.RiverWindowManagerClient.Log($"unknown builtin '{bname}'");
                }

                return;
        }
    }

    private static string EscapeForShell(string s) => "'" + s.Replace("'", "'\\''") + "'";
}
