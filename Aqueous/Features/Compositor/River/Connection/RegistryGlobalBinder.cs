namespace Aqueous.Features.Compositor.River.Connection;

/// <summary>
/// PR 9.12 §2.8: top-level seam for the <c>wl_registry::global</c>
/// dispatch. Owns the subscription to <see cref="RegistryBinder.Discovered"/>
/// and delegates the per-interface bind decision to the god class
/// while it still owns the raw bind-site fields. Subsequent sub-steps
/// (§2.10/§2.13) will lift the body in here once
/// <see cref="WaylandBindSiteState"/> is the sole owner of the
/// proxy pointers.
/// </summary>
internal sealed class RegistryGlobalBinder
{
    private readonly RiverWindowManagerClient _client;

    internal RegistryGlobalBinder(RiverWindowManagerClient client)
    {
        _client = client;
    }

    /// <summary>
    /// Entry point used as the <c>Discovered</c> event handler.
    /// Mirrors the prior <c>OnGlobalDiscovered</c> signature so the
    /// subscription site can swap in this delegate without behaviour
    /// change.
    /// </summary>
    internal void Bind(RegistryGlobal global) => _client.HandleRegistryGlobal(global);
}
