using System.Collections.Generic;
using Aqueous.Features.Layout;
using Xunit;

namespace Aqueous.Tests;

/// <summary>
/// Pins the contract of <see cref="LayoutId"/> — equality, normalization,
/// dictionary-key behaviour, and the documented invariant that
/// <c>IsBuiltin</c> is informational only (resolution never branches on it).
/// </summary>
public class LayoutIdTests
{
    [Fact]
    public void From_TrimsAndLowercases()
    {
        Assert.Equal("tile", LayoutId.From("Tile").Value);
        Assert.Equal("tile", LayoutId.From("  TILE  ").Value);
        Assert.Equal("myorg.spiral", LayoutId.From("MyOrg.Spiral").Value);
    }

    [Fact]
    public void From_NullBecomesEmpty()
    {
        Assert.Equal(string.Empty, LayoutId.From(null).Value);
    }

    [Fact]
    public void Builtins_AreReportedAsBuiltin()
    {
        Assert.True(LayoutId.Tile.IsBuiltin);
        Assert.True(LayoutId.Float.IsBuiltin);
        Assert.True(LayoutId.Monocle.IsBuiltin);
        Assert.True(LayoutId.Grid.IsBuiltin);
    }

    [Fact]
    public void PluginIds_AreNotBuiltin()
    {
        Assert.False(LayoutId.From("myorg.spiral").IsBuiltin);
        Assert.False(LayoutId.From("custom").IsBuiltin);
    }

    [Fact]
    public void Equality_IsCaseInsensitiveAfterFromNormalization()
    {
        Assert.Equal(LayoutId.From("TILE"), LayoutId.From("tile"));
        Assert.Equal(LayoutId.From("Tile"), LayoutId.Tile);
    }

    [Fact]
    public void DictionaryKey_RoundTrips()
    {
        var map = new Dictionary<LayoutId, string>
        {
            [LayoutId.Tile] = "TileLayout",
            [LayoutId.From("MyOrg.Spiral")] = "SpiralLayout",
        };

        Assert.Equal("TileLayout", map[LayoutId.From("tile")]);
        Assert.Equal("SpiralLayout", map[LayoutId.From("myorg.spiral")]);
    }

    [Fact]
    public void ToString_ReturnsValue()
    {
        Assert.Equal("tile", LayoutId.Tile.ToString());
        Assert.Equal("myorg.spiral", LayoutId.From("MyOrg.Spiral").ToString());
    }
}
