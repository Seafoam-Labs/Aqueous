using System;
using System.Collections.Generic;
using Aqueous.WM.Features.Layout.Builtin;

namespace Aqueous.WM.Features.Layout;

/// <summary>
/// Maps layout id strings to factories. Built-ins are eagerly registered
/// in the constructor; <see cref="Register"/> is the public seam for an
/// (out-of-scope, follow-up) plugin loader.
/// </summary>
public sealed class LayoutRegistry
{
    private readonly Dictionary<string, ILayoutFactory> _factories =
        new(StringComparer.Ordinal);

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
        if (factory is null) throw new ArgumentNullException(nameof(factory));
        _factories[factory.Id] = factory;
    }

    public bool TryResolve(string id, out ILayoutFactory factory) =>
        _factories.TryGetValue(id, out factory!);

    public ILayoutEngine Create(string id)
    {
        if (!_factories.TryGetValue(id, out var f))
            throw new KeyNotFoundException($"Layout '{id}' is not registered.");
        return f.Create();
    }

    public IEnumerable<ILayoutFactory> All => _factories.Values;

    public bool Contains(string id) => _factories.ContainsKey(id);
}
