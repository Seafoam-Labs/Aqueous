using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Aqueous.Features.Compositor.River;

namespace Aqueous.Features.Bindings;

/// <summary>
/// PR 9.12 §2.13 Step 4 — DI singleton replacing the
/// <c>_keyBindings</c> / <c>_customBindingActions</c> dictionaries
/// and the <c>_selfHandle</c> GCHandle pointer previously owned by
/// <see cref="Aqueous.Features.Compositor.River.RiverWindowManagerClient"/>.
///
/// <para>
/// <see cref="KeyBindings"/> maps a bound <c>river_xkb_binding_v1</c>
/// proxy to its built-in action (or <see cref="KeyBindingAction.Custom"/>).
/// <see cref="CustomBindingActions"/> maps the same proxy to the
/// free-form action verb (<c>spawn:</c>/<c>set_layout:</c>/<c>builtin:</c>)
/// for chords registered through <c>[keybinds].custom</c>.
/// </para>
///
/// <para>
/// <see cref="SelfHandlePtr"/> is the pinned GCHandle pointer that
/// the native dispatcher's user-data callback rehydrates back to the
/// owning client. It is set once by <c>RiverWindowManagerClient</c>
/// during connect; the registrar reads it when binding the dispatcher
/// to a newly created binding proxy.
/// </para>
///
/// <para>Pump-thread only.</para>
/// </summary>
internal sealed class KeyBindingsRegistry
{
    public Dictionary<IntPtr, KeyBindingAction> KeyBindings { get; } = new();
    public Dictionary<IntPtr, string> CustomBindingActions { get; } = new();
    public IntPtr SelfHandlePtr { get; set; }
}
