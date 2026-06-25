using System;
using Aqueous.Features.Layout;
using Xunit;

namespace Aqueous.Tests;

/// <summary>
/// Per-workspace layout selection: the layout id is keyed by (output, workspace number) rather than
/// per-output, so each workspace remembers its own layout, a <c>set_layout_*</c> keybinding changes
/// only the focused workspace, and <c>[[workspace]]</c> config blocks predeclare a workspace's
/// layout. Engines are pure, so no Wayland fixture is required.
/// </summary>
public class LayoutPerWorkspaceTests
{
    private const int Ws1 = 1;         // 1-based workspace number
    private const int Ws2 = 2;         // 1-based workspace number

    // -- Config parsing ----------------------------------------------

    [Fact]
    public void Parse_WorkspaceIndexBlock_PopulatesPerWorkspace()
    {
        var cfg = LayoutConfig.Parse("""
            [[workspace]]
            workspace = 1
            layout    = "monocle"
            """);

        Assert.True(cfg.PerWorkspace.TryGetValue(Ws1, out var id));
        Assert.Equal("monocle", id);
        Assert.Empty(cfg.PerOutputWorkspace);
    }

    [Fact]
    public void Parse_WorkspaceRawTagsKey_IsRejected()
    {
        // The legacy `tags = N` bitmask key was removed in favour of `workspace = N`; a block that
        // only carries `tags` lacks a workspace number and is therefore dropped.
        var cfg = LayoutConfig.Parse("""
            [[workspace]]
            tags   = 2
            layout = "grid"
            """);

        Assert.Empty(cfg.PerWorkspace);
        Assert.Empty(cfg.PerOutputWorkspace);
    }

    [Fact]
    public void Parse_WorkspaceWithOutput_PopulatesPerOutputWorkspace()
    {
        var cfg = LayoutConfig.Parse("""
            [[workspace]]
            output    = "DP-1"
            workspace = 2
            layout    = "grid"
            """);

        Assert.True(cfg.PerOutputWorkspace.TryGetValue(("DP-1", Ws2), out var id));
        Assert.Equal("grid", id);
        Assert.Empty(cfg.PerWorkspace);
    }

    [Fact]
    public void ResolveLayoutForWorkspace_OutputSpecificWinsOverGeneric()
    {
        var cfg = LayoutConfig.Parse("""
            [[workspace]]
            workspace = 1
            layout    = "monocle"

            [[workspace]]
            output    = "DP-1"
            workspace = 1
            layout    = "grid"
            """);

        Assert.Equal("grid", cfg.ResolveLayoutForWorkspace("DP-1", Ws1));   // output+ws wins
        Assert.Equal("monocle", cfg.ResolveLayoutForWorkspace("HDMI-A-1", Ws1)); // falls to ws-only
        Assert.Null(cfg.ResolveLayoutForWorkspace("DP-1", Ws2));            // no match
    }

    [Fact]
    public void ResolveLayoutForWorkspaceNumber_OutputSpecificWinsOverGeneric()
    {
        var cfg = LayoutConfig.Parse("""
            [[workspace]]
            workspace = 1
            layout    = "monocle"

            [[workspace]]
            output    = "DP-1"
            workspace = 1
            layout    = "grid"
            """);

        Assert.Equal("grid", cfg.ResolveLayoutForWorkspace("DP-1", Ws1));
        Assert.Equal("monocle", cfg.ResolveLayoutForWorkspace("HDMI-A-1", Ws1));
        Assert.Null(cfg.ResolveLayoutForWorkspace("DP-1", Ws2));
    }

    [Fact]
    public void ResolveLayoutForWorkspaceNumber_NonPositiveYieldsNull()
    {
        var cfg = LayoutConfig.Parse("""
            [[workspace]]
            workspace = 1
            layout    = "monocle"
            """);

        Assert.Null(cfg.ResolveLayoutForWorkspace(null, 0));
        Assert.Null(cfg.ResolveLayoutForWorkspace(null, -1));
    }

    [Fact]
    public void ResolveLayoutId_ByWorkspaceNumber_SelectsConfiguredLayout()
    {
        var registry = new LayoutRegistry();
        var cfg = LayoutConfig.Parse("""
            [layout]
            default = "tile"

            [[workspace]]
            workspace = 2
            layout    = "grid"

            [[workspace]]
            workspace = 5
            layout    = "monocle"
            """);
        var ctrl = new LayoutController(registry, cfg);
        var output = new IntPtr(0xEE);

        Assert.Equal("grid", ctrl.ResolveLayoutId(output, "DP-1", 2));
        Assert.Equal("monocle", ctrl.ResolveLayoutId(output, "DP-1", 5));
        // Unconfigured workspace falls through to [layout].default.
        Assert.Equal("tile", ctrl.ResolveLayoutId(output, "DP-1", 3));
    }

    // -- Controller per-workspace id ---------------------------------

    [Fact]
    public void SetLayoutForWorkspace_DoesNotAffectSiblingWorkspace()
    {
        var registry = new LayoutRegistry();
        var ctrl = new LayoutController(registry, LayoutConfig.Default); // default = tile
        var output = new IntPtr(0xAA);

        ctrl.SetLayoutForWorkspace(output, Ws1, "monocle");

        Assert.Equal("monocle", ctrl.ResolveLayoutId(output, null, Ws1));
        // Sibling workspace keeps the global default.
        Assert.Equal("tile", ctrl.ResolveLayoutId(output, null, Ws2));
    }

    [Fact]
    public void SwitchingWorkspace_RestoresThatWorkspacesLayout()
    {
        var registry = new LayoutRegistry();
        var ctrl = new LayoutController(registry, LayoutConfig.Default);
        var output = new IntPtr(0xBB);

        ctrl.SetLayoutForWorkspace(output, Ws1, "monocle");
        ctrl.SetLayoutForWorkspace(output, Ws2, "grid");

        // Round-trip A -> B -> A: each workspace restores its own id, not the last-set one.
        Assert.Equal("monocle", ctrl.ResolveLayoutId(output, null, Ws1));
        Assert.Equal("grid", ctrl.ResolveLayoutId(output, null, Ws2));
        Assert.Equal("monocle", ctrl.ResolveLayoutId(output, null, Ws1));
    }

    [Fact]
    public void ConfigWorkspaceDefault_HonouredThenOverridableByKeybinding()
    {
        var registry = new LayoutRegistry();
        var cfg = LayoutConfig.Parse("""
            [layout]
            default = "tile"

            [[workspace]]
            workspace = 1
            layout    = "monocle"
            """);
        var ctrl = new LayoutController(registry, cfg);
        var output = new IntPtr(0xCC);

        // First visit: config workspace default applies.
        Assert.Equal("monocle", ctrl.ResolveLayoutId(output, "DP-1", Ws1));
        // Other workspace falls through to [layout].default.
        Assert.Equal("tile", ctrl.ResolveLayoutId(output, "DP-1", Ws2));

        // A set_layout_* keybinding (per workspace) overrides the config default for Ws1 only.
        ctrl.SetLayoutForWorkspace(output, Ws1, "grid");
        Assert.Equal("grid", ctrl.ResolveLayoutId(output, "DP-1", Ws1));
    }

    [Fact]
    public void SetLayoutForOutput_AppliesAcrossWorkspaces()
    {
        var registry = new LayoutRegistry();
        var ctrl = new LayoutController(registry, LayoutConfig.Default);
        var output = new IntPtr(0xDD);

        // Give one workspace an explicit id first; SetLayoutForOutput is "whole monitor" and clears it.
        ctrl.SetLayoutForWorkspace(output, Ws1, "grid");
        ctrl.SetLayoutForOutput(output, "monocle");

        Assert.Equal("monocle", ctrl.ResolveLayoutId(output, null, Ws1));
        Assert.Equal("monocle", ctrl.ResolveLayoutId(output, null, Ws2));
    }
}
