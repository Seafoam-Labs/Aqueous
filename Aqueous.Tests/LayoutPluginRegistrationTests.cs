using System;
using System.Collections.Generic;
using Aqueous.Features.Layout;
using Xunit;

namespace Aqueous.Tests;

/// <summary>
/// Pins the plugin-readiness contract delivered by Phase 4: a custom
/// <see cref="ILayoutFactory"/> registered after construction must be
/// resolvable through the registry and the controller, unknown ids in
/// the config survive parsing, the <see cref="LayoutOptions.Extra"/> bag
/// round-trips arbitrary keys, and re-registering an existing id is
/// last-wins.
/// </summary>
public class LayoutPluginRegistrationTests
{
    private sealed class StubEngine : ILayoutEngine
    {
        public string Id { get; }

        public StubEngine(string id) => Id = id;

        public IReadOnlyList<WindowPlacement> Arrange(
            Rect usableArea,
            IReadOnlyList<WindowEntryView> visibleWindows,
            IntPtr focusedWindow,
            LayoutOptions opts,
            ref object? perOutputState) => Array.Empty<WindowPlacement>();
    }

    private sealed class StubFactory : ILayoutFactory
    {
        public string Id { get; }
        public string DisplayName { get; }
        private readonly StubEngine _shared;

        public StubFactory(string id, string display)
        {
            Id = id;
            DisplayName = display;
            _shared = new StubEngine(id);
        }

        public ILayoutEngine Create() => _shared;
    }

    [Fact]
    public void Register_LatePlugin_BecomesResolvable()
    {
        var registry = new LayoutRegistry();
        Assert.False(registry.Contains("myorg.spiral"));

        registry.Register(new StubFactory("myorg.spiral", "Spiral"));

        Assert.True(registry.Contains("myorg.spiral"));
        Assert.True(registry.Contains(LayoutId.From("MyOrg.Spiral")));
        Assert.IsType<StubEngine>(registry.Create("myorg.spiral"));
    }

    [Fact]
    public void Register_IsCaseInsensitive()
    {
        var registry = new LayoutRegistry();
        registry.Register(new StubFactory("MyOrg.Spiral", "Spiral"));

        Assert.True(registry.Contains("myorg.spiral"));
        Assert.True(registry.Contains("MYORG.SPIRAL"));
    }

    [Fact]
    public void Register_DuplicateId_IsLastWins()
    {
        var registry = new LayoutRegistry();
        registry.Register(new StubFactory("custom", "First"));
        registry.Register(new StubFactory("custom", "Second"));

        var resolved = false;
        if (registry.TryResolve("custom", out var f))
        {
            resolved = true;
            Assert.Equal("Second", f.DisplayName);
        }

        Assert.True(resolved);
    }

    [Fact]
    public void Controller_LateRegisteredPlugin_IsSelectable()
    {
        var registry = new LayoutRegistry();
        var config = LayoutConfig.Default;
        var controller = new LayoutController(registry, config);

        // Plugin registered after controller construction (the embedding
        // scenario: parse config → load plugins → resolve).
        registry.Register(new StubFactory("myorg.spiral", "Spiral"));

        var output = new IntPtr(1);
        controller.SetLayoutForOutput(output, LayoutId.From("myorg.spiral"));

        Assert.Equal("myorg.spiral",
            controller.ResolveLayoutId(output, outputName: null));
    }

    [Fact]
    public void Loader_UnknownLayoutId_SurvivesInSlots()
    {
        var cfg = LayoutConfig.Parse("""
            [layout.slots]
            primary = "myorg.spiral"
            """);

        Assert.Equal("myorg.spiral", cfg.Slots["primary"]);
    }

    [Fact]
    public void Loader_UnknownLayoutId_SurvivesInPerOutput()
    {
        var cfg = LayoutConfig.Parse("""
            [[output]]
            name = "DP-1"
            layout = "myorg.spiral"
            """);

        Assert.True(cfg.PerOutput.TryGetValue("DP-1", out var id));
        Assert.Equal("myorg.spiral", id);
    }

    [Fact]
    public void Loader_PluginExtraKeys_RoundTripIntoOptionsExtra()
    {
        var cfg = LayoutConfig.Parse("""
            [layout.options.myorg.spiral]
            angle = "1.5"
            wrap = "true"
            """);

        // The TOML section is "layout.options.<id>"; everything after the
        // prefix is the layout id verbatim.
        var opts = cfg.OptionsFor(LayoutId.From("myorg.spiral"));
        Assert.Equal("1.5", opts.GetExtra("angle"));
        Assert.Equal(1.5, opts.GetExtraDouble("angle", 0.0));
        Assert.True(opts.GetExtraBool("wrap", false));
    }

    [Fact]
    public void OptionsFor_LayoutId_AndStringOverloads_AgreeForBuiltin()
    {
        var cfg = LayoutConfig.Default;
        var byString = cfg.OptionsFor("tile");
        var byId = cfg.OptionsFor(LayoutId.Tile);

        Assert.Equal(byString.GapsOuter, byId.GapsOuter);
        Assert.Equal(byString.GapsInner, byId.GapsInner);
        Assert.Equal(byString.MasterRatio, byId.MasterRatio);
    }
}
