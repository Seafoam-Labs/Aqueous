using System;
using System.Collections.Generic;
using Aqueous.Features.Layout.Builtin;

namespace Aqueous.Features.Layout;

/// <summary>
/// Maps layout ids to factories. Built-ins are eagerly registered in the
/// constructor; <see cref="Register"/> is the public seam for plugin
/// authors — call it before the first <see cref="Create(string)"/> on
/// your custom layout's id.
/// </summary>
/// <remarks>
/// <para>
/// Lookups are case-insensitive (the underlying dictionary uses
/// <see cref="StringComparer.OrdinalIgnoreCase"/>) so an id supplied by
/// TOML, a key-binding payload, or a CLI flag matches a factory
/// regardless of casing. <see cref="LayoutId"/> overloads are provided
/// alongside the legacy <see cref="string"/> overloads.
/// </para>
/// <para>
/// Re-registering an existing id is allowed; the most recent factory
/// wins. This supports hot-reload of plugin assemblies in development
/// without restarting the WM.
/// </para>
/// </remarks>
public sealed class LayoutRegistry
{
    private readonly Dictionary<string, ILayoutFactory> _factories =
        new(StringComparer.OrdinalIgnoreCase);

    public LayoutRegistry()
    {
        Register(new TileLayoutFactory());
        Register(new MonocleLayoutFactory());
        Register(new GridLayoutFactory());
        Register(new FloatingLayoutFactory());
        Register(new ScrollingLayoutFactory());
    }

    public void Register(ILayoutFactory factory)
    {
        if (factory is null)
        {
            throw new ArgumentNullException(nameof(factory));
        }

        _factories[factory.Id] = factory;
    }

    public bool TryResolve(string id, out ILayoutFactory factory) =>
        _factories.TryGetValue(id, out factory!);

    /// <summary>
    /// <see cref="LayoutId"/>-typed overload of
    /// <see cref="TryResolve(string, out ILayoutFactory)"/>.
    /// </summary>
    public bool TryResolve(LayoutId id, out ILayoutFactory factory) =>
        _factories.TryGetValue(id.Value, out factory!);

    public ILayoutEngine Create(string id)
    {
        if (!_factories.TryGetValue(id, out var f))
        {
            throw new KeyNotFoundException($"Layout '{id}' is not registered.");
        }

        return f.Create();
    }

    /// <summary>
    /// <see cref="LayoutId"/>-typed overload of <see cref="Create(string)"/>.
    /// </summary>
    public ILayoutEngine Create(LayoutId id) => Create(id.Value);

    public IEnumerable<ILayoutFactory> All => _factories.Values;

    public bool Contains(string id) => _factories.ContainsKey(id);

    /// <summary>
    /// <see cref="LayoutId"/>-typed overload of <see cref="Contains(string)"/>.
    /// </summary>
    public bool Contains(LayoutId id) => _factories.ContainsKey(id.Value);
}
