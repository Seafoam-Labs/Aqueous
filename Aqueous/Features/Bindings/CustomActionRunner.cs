using System;
using System.Diagnostics;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Focus;
using Aqueous.Features.State;

namespace Aqueous.Features.Bindings;

/// <summary>
/// : Top-level <see cref="ICustomActionRunner"/> implementation. ctor converted from a single <see
/// cref="RiverWindowManagerClient"/> reference to fine-grained service injection. the residual
/// <see cref="RiverWindowManagerClient"/> ctor argument is gone — the runner never actually
/// consumed it. The static <c>RiverLog.Write</c> helper used for error reporting is a stand-alone
/// forwarder that doesn't require an instance.
/// </summary>
internal sealed class CustomActionRunner : ICustomActionRunner
{
    private readonly IKeyBindingRouter _router;
    private readonly IFocusService _focusService;
    private readonly WindowStateController _windowState;

    public CustomActionRunner(
        IKeyBindingRouter router,
        IFocusService focusService,
        WindowStateController windowState)
    {
        _router = router ?? throw new ArgumentNullException(nameof(router));
        _focusService = focusService ?? throw new ArgumentNullException(nameof(focusService));
        _windowState = windowState ?? throw new ArgumentNullException(nameof(windowState));
    }

    /// <summary>
    /// Dispatch a custom action verb. Recognised forms:
    /// <list type="bullet">
    /// <item>
    /// <c>spawn:&lt;cmd&gt;</c> — fork/exec via <c>/bin/sh -c</c>.
    /// </item>
    /// <item>
    /// <c>set_layout:&lt;id-or-slot&gt;</c> — switch active layout.
    /// </item>
    /// <item>
    /// <c>builtin:&lt;action_name&gt;</c> — invoke a built-in.
    /// </item>
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
                Aqueous.Diagnostics.RiverLog.Write($"unknown custom action verb '{head}'");
                break;
        }
    }

    /// <summary>
    /// Downcast the DI-injected <see cref="IKeyBindingRouter"/> to the concrete <see
    /// cref="KeyBindingRouter"/> for the two entry points custom verbs reach that aren't on the
    /// interface (<c>SetLayoutByIdOrSlot</c>, <c>InvokeBuiltin</c>). Safe because DI only registers
    /// exactly one router instance of this concrete type.
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
            Aqueous.Diagnostics.RiverLog.Write($"spawn '{arg}' failed: {ex.Message}");
        }
    }

    private void RunBuiltinVerb(string arg)
    {
        // Phase B1e Pass B: split one optional trailing ":argument" segment so chords like
        // builtin:toggle_scratchpad_named:term can dispatch to the parameterised actions while preserving
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
                    Aqueous.Diagnostics.RiverLog.Write("builtin:toggle_scratchpad_named requires :name");
                    return;
                }

                _windowState.ToggleScratchpad(barg);
                return;
            case "send_to_scratchpad_named":
                if (barg.Length == 0)
                {
                    Aqueous.Diagnostics.RiverLog.Write("builtin:send_to_scratchpad_named requires :name");
                    return;
                }

                if (_focusService.TryGetFocusedAlive(out var focusedForScratchpad))
                {
                    _windowState.SendToScratchpad(new WindowProxy(focusedForScratchpad), barg);
                }
                else
                {
                    Aqueous.Diagnostics.RiverLog.Write("builtin:send_to_scratchpad_named: no focused window");
                }

                return;
            default:
                if (KeyBindingActionTable.Map.TryGetValue(bname, out var b))
                {
                    ConcreteRouter().InvokeBuiltin(b);
                }
                else
                {
                    Aqueous.Diagnostics.RiverLog.Write($"unknown builtin '{bname}'");
                }

                return;
        }
    }

    private static string EscapeForShell(string s) => "'" + s.Replace("'", "'\\''") + "'";
}
