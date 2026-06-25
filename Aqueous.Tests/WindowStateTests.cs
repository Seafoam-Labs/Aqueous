using System;
using System.Collections.Generic;
using Aqueous.Features.Layout;
using Aqueous.Features.State;
using Xunit;

namespace Aqueous.Tests;

/// <summary>
/// Pure unit tests for <see cref="WindowStateController"/> built against an in-memory
/// <see cref="IWindowStateHost"/> fake. The fake never touches Wayland; it only records mutations
/// and answers queries.
/// </summary>
public class WindowStateTests
{
    // ------- FakeHost --------------------------------------------------

    private sealed class FakeHost : IWindowStateHost
    {
        public readonly Dictionary<WindowProxy, WindowStateData> Data = new();
        public readonly Dictionary<OutputProxy, WindowProxy> Fullscreen = new();
        public readonly Dictionary<WindowProxy, Rect> Geom = new();
        public readonly Dictionary<OutputProxy, Rect> Outputs = new();
        public WindowProxy CurrentFocus;
        public OutputProxy CurrentOutput;
        public readonly List<string> Logs = new();
        public readonly List<(WindowProxy win, OutputProxy output)> FsEmits = new();
        public readonly List<WindowProxy> UnfsEmits = new();
        public readonly List<string> Spawned = new();
        public readonly List<OutputProxy> Renders = new();

        public WindowStateData? Get(WindowProxy w) => Data.TryGetValue(w, out var d) ? d : null;
        public WindowProxy FocusedWindow => CurrentFocus;
        public OutputProxy FocusedOutput => CurrentOutput;
        public Rect OutputRect(OutputProxy o) => Outputs.TryGetValue(o, out var r) ? r : new Rect(0, 0, 1920, 1080);
        public Rect UsableArea(OutputProxy o) => OutputRect(o);
        public WindowProxy GetFullscreenWindow(OutputProxy o) => Fullscreen.TryGetValue(o, out var w) ? w : WindowProxy.Zero;
        public void SetFullscreenWindow(OutputProxy o, WindowProxy w)
        {
            if (w.IsZero)
            {
                Fullscreen.Remove(o);
            }
            else
            {
                Fullscreen[o] = w;
            }
        }
        public void Focus(WindowProxy w) => CurrentFocus = w;
        public void FocusNextOnOutput(OutputProxy o)
        {
            // Pick any other window data entry on this output as the new focus.
            foreach (var kv in Data)
            {
                if (kv.Key != CurrentFocus && kv.Value.State != WindowState.Minimized
                    && kv.Value.State != WindowState.Scratchpad)
                {
                    CurrentFocus = kv.Key; return;
                }
            }
            CurrentFocus = WindowProxy.Zero;
        }
        public void RequestRender(OutputProxy o) => Renders.Add(o);
        public void EmitForeignToplevelFullscreen(WindowProxy w, OutputProxy o) => FsEmits.Add((w, o));
        public void EmitForeignToplevelUnfullscreen(WindowProxy w) => UnfsEmits.Add(w);
        public void Spawn(string cmd) => Spawned.Add(cmd);
        public readonly List<WindowProxy> InvalidatedFloatRects = new();
        public void InvalidateFloatRect(WindowProxy window) => InvalidatedFloatRects.Add(window);
        public readonly List<(WindowProxy win, bool maximized)> MaximizedStateEmits = new();
        public void SetToplevelMaximizedState(WindowProxy window, bool maximized) =>
            MaximizedStateEmits.Add((window, maximized));

        public void Log(string m) => Logs.Add(m);
        public Rect CurrentGeometry(WindowProxy w) => Geom.TryGetValue(w, out var r) ? r : new Rect(100, 100, 400, 300);
    }

    private static (FakeHost host, WindowStateController ctrl, WindowProxy w1, WindowProxy w2, OutputProxy o1)
        Setup(StateConfig? cfg = null)
    {
        var host = new FakeHost();
        var o1 = new OutputProxy(new IntPtr(0xA1));
        host.Outputs[o1] = new Rect(0, 0, 1920, 1080);
        host.CurrentOutput = o1;
        var w1 = new WindowProxy(new IntPtr(0xB1));
        var w2 = new WindowProxy(new IntPtr(0xB2));
        host.Data[w1] = new WindowStateData { Handle = w1, PinnedOutput = o1 };
        host.Data[w2] = new WindowStateData { Handle = w2, PinnedOutput = o1 };
        host.Geom[w1] = new Rect(10, 10, 800, 600);
        host.Geom[w2] = new Rect(900, 10, 800, 600);
        host.CurrentFocus = w1;
        var ctrl = new WindowStateController(host, new ScratchpadRegistry(), cfg);
        return (host, ctrl, w1, w2, o1);
    }

    // ------- Fullscreen ------------------------------------------------

    [Fact]
    public void ToggleFullscreen_PromotesAndRestores()
    {
        var (host, ctrl, w1, _, o1) = Setup();

        Assert.True(ctrl.ToggleFullscreen(w1));
        Assert.Equal(WindowState.Fullscreen, host.Data[w1].State);
        Assert.Equal(w1, host.GetFullscreenWindow(o1));
        Assert.Single(host.FsEmits);

        Assert.True(ctrl.ToggleFullscreen(w1));
        Assert.Equal(WindowState.Tiled, host.Data[w1].State);
        Assert.Equal(WindowProxy.Zero, host.GetFullscreenWindow(o1));
        Assert.Single(host.UnfsEmits);
    }

    [Fact]
    public void ToggleFullscreen_SingleFsRulePerOutput()
    {
        var (host, ctrl, w1, w2, o1) = Setup();

        ctrl.ToggleFullscreen(w1);
        Assert.Equal(w1, host.GetFullscreenWindow(o1));

        ctrl.ToggleFullscreen(w2);
        Assert.Equal(WindowState.Tiled, host.Data[w1].State);  // demoted
        Assert.Equal(WindowState.Fullscreen, host.Data[w2].State);
        Assert.Equal(w2, host.GetFullscreenWindow(o1));
    }

    [Fact]
    public void ClientRequestedFullscreen_IsHonored()
    {
        var (host, ctrl, w1, _, o1) = Setup();
        ctrl.OnClientRequestedFullscreen(w1, o1);
        Assert.Equal(WindowState.Fullscreen, host.Data[w1].State);
    }

    // ------- Maximize --------------------------------------------------

    [Fact]
    public void ToggleMaximize_RoundTripsThroughTiled()
    {
        var (host, ctrl, w1, _, _) = Setup();
        Assert.True(ctrl.ToggleMaximize(w1));
        Assert.Equal(WindowState.Maximized, host.Data[w1].State);
        Assert.True(ctrl.ToggleMaximize(w1));
        Assert.Equal(WindowState.Tiled, host.Data[w1].State);
    }

    [Fact]
    public void ToggleMaximize_NoOpWhileFullscreen()
    {
        var (host, ctrl, w1, _, _) = Setup();
        ctrl.ToggleFullscreen(w1);
        Assert.False(ctrl.ToggleMaximize(w1));
        Assert.Equal(WindowState.Fullscreen, host.Data[w1].State);
    }

    // ------- InvalidateFloatRect (maximize-restore round-trip) ---------

    [Fact]
    public void ToggleMaximize_Enter_DoesNotInvalidateFloatRect()
    {
        // Entering Maximized must not call InvalidateFloatRect — the floating loop's diff-gates need to
        // be preserved so that the maximize emit itself is the one that updates LastPos/LastHint.
        var (host, ctrl, w1, _, _) = Setup();
        Assert.True(ctrl.ToggleMaximize(w1));
        Assert.Empty(host.InvalidatedFloatRects);
    }

    [Fact]
    public void ToggleMaximize_RestoreToFloating_InvalidatesFloatRect()
    {
        // Repro for the maximize-button regression: on the way OUT of Maximized into Floating, the
        // controller must call _host.InvalidateFloatRect(window) so LayoutProposer re-seeds FloatX/Y/W/H
        // from the restored FloatingGeom and re-arms its position/size diff-gates. Without this, the
        // restored window stays glued to the maximized rect.
        var (host, ctrl, w1, _, _) = Setup();
        // Pre-arm: window is Floating with a remembered geometry.
        host.Data[w1].State = WindowState.Floating;
        host.Data[w1].FloatingGeom = new Rect(120, 80, 640, 480);

        Assert.True(ctrl.ToggleMaximize(w1));     // Floating → Maximized
        Assert.Empty(host.InvalidatedFloatRects); // not on enter
        Assert.True(ctrl.ToggleMaximize(w1));     // Maximized → Floating
        Assert.Equal(WindowState.Floating, host.Data[w1].State);
        Assert.Single(host.InvalidatedFloatRects);
        Assert.Equal(w1, host.InvalidatedFloatRects[0]);
    }

    [Fact]
    public void ToggleMaximize_Enter_EmitsMaximizedTrue()
    {
        // Strict xdg-shell clients (Chromium, Alacritty) read the xdg_toplevel.configure state array, not
        // the size hint, to decide layout. The controller must announce maximized=true on entry so that
        // array carries the maximized flag.
        var (host, ctrl, w1, _, _) = Setup();
        Assert.True(ctrl.ToggleMaximize(w1));
        Assert.Single(host.MaximizedStateEmits);
        Assert.Equal((w1, true), host.MaximizedStateEmits[0]);
    }

    [Fact]
    public void ToggleMaximize_RestoreToFloating_EmitsMaximizedFalse()
    {
        // Repro for Chromium "two clicks to restore" / Alacritty "never restores": the controller must
        // announce maximized=false on restore so the state array drops the maximized flag and strict
        // clients accept the float-size configure on the first cycle.
        var (host, ctrl, w1, _, _) = Setup();
        host.Data[w1].State = WindowState.Floating;
        host.Data[w1].FloatingGeom = new Rect(120, 80, 640, 480);

        ctrl.ToggleMaximize(w1);     // enter
        ctrl.ToggleMaximize(w1);     // restore

        Assert.Equal(2, host.MaximizedStateEmits.Count);
        Assert.Equal((w1, true), host.MaximizedStateEmits[0]);
        Assert.Equal((w1, false), host.MaximizedStateEmits[1]);
    }

    [Fact]
    public void ToggleMaximize_RestoreToTiled_EmitsMaximizedFalse()
    {
        // Same contract as the floating-restore path, but exercising the Tiled previous-state branch —
        // most CSD-button maximize clicks land here, not in Floating.
        var (host, ctrl, w1, _, _) = Setup();
        host.Data[w1].State = WindowState.Tiled;

        ctrl.ToggleMaximize(w1);
        ctrl.ToggleMaximize(w1);

        Assert.Equal(WindowState.Tiled, host.Data[w1].State);
        Assert.Equal(2, host.MaximizedStateEmits.Count);
        Assert.Equal((w1, true), host.MaximizedStateEmits[0]);
        Assert.Equal((w1, false), host.MaximizedStateEmits[1]);
    }

    [Fact]
    public void ToggleMaximize_RestoreToFloating_RestoresPreFsGeom()
    {
        // The InvalidateFloatRect call only matters if the controller also writes the pre-maximize rect
        // back into FloatingGeom; pin that contract here so a future can't silently drop it.
        var (host, ctrl, w1, _, _) = Setup();
        host.Data[w1].State = WindowState.Floating;
        host.Data[w1].FloatingGeom = new Rect(120, 80, 640, 480);
        host.Geom[w1] = new Rect(120, 80, 640, 480);

        ctrl.ToggleMaximize(w1);
        // Mutate the remembered float rect while maximized to prove the restore branch overwrites it from
        // PreFsGeom (not the other way).
        host.Data[w1].FloatingGeom = new Rect(0, 0, 1, 1);
        ctrl.ToggleMaximize(w1);

        Assert.Equal(new Rect(120, 80, 640, 480), host.Data[w1].FloatingGeom);
        Assert.Single(host.InvalidatedFloatRects);
    }

    // ------- Floating --------------------------------------------------

    [Fact]
    public void ToggleFloating_AssignsDefaultRect()
    {
        var (host, ctrl, w1, _, _) = Setup();
        Assert.True(ctrl.ToggleFloating(w1));
        Assert.Equal(WindowState.Floating, host.Data[w1].State);
        Assert.NotNull(host.Data[w1].FloatingGeom);
        Assert.True(ctrl.ToggleFloating(w1));
        Assert.Equal(WindowState.Tiled, host.Data[w1].State);
    }

    [Fact]
    public void ToggleFloating_NoOpFromOverlayState()
    {
        var (host, ctrl, w1, _, _) = Setup();
        ctrl.ToggleFullscreen(w1);
        Assert.False(ctrl.ToggleFloating(w1));
    }

    // ------- Minimize / UnminimizeLast ---------------------------------

    [Fact]
    public void ToggleMinimize_HidesAndPushesMru()
    {
        var (host, ctrl, w1, w2, _) = Setup();
        ctrl.ToggleMinimize(w1);
        Assert.Equal(WindowState.Minimized, host.Data[w1].State);
        Assert.Single(ctrl.MinimizedMru);
        // Focus left w1 since FocusNextOnOutput moved it.
        Assert.NotEqual(w1, host.FocusedWindow);

        ctrl.ToggleMinimize(w2);
        Assert.Equal(2, ctrl.MinimizedMru.Count);
    }

    [Fact]
    public void UnminimizeLast_PopsLifo()
    {
        var (host, ctrl, w1, w2, _) = Setup();
        ctrl.ToggleMinimize(w1);
        ctrl.ToggleMinimize(w2);

        Assert.True(ctrl.UnminimizeLast());
        Assert.Equal(WindowState.Tiled, host.Data[w2].State); // w2 was top
        Assert.Equal(WindowState.Minimized, host.Data[w1].State);
        Assert.True(ctrl.UnminimizeLast());
        Assert.Equal(WindowState.Tiled, host.Data[w1].State);
        Assert.False(ctrl.UnminimizeLast());
    }

    [Fact]
    public void UnminimizeLast_SkipsDeadHandles()
    {
        var (host, ctrl, w1, w2, _) = Setup();
        ctrl.ToggleMinimize(w1);
        ctrl.ToggleMinimize(w2);
        // Simulate w2 being destroyed while minimized
        host.Data.Remove(w2);
        ctrl.OnWindowDestroyed(w2);

        Assert.True(ctrl.UnminimizeLast());
        Assert.Equal(WindowState.Tiled, host.Data[w1].State);
    }

    // ------- Scratchpad ------------------------------------------------

    [Fact]
    public void SendToScratchpad_HidesWindowAndOccupiesPad()
    {
        var (host, ctrl, w1, _, _) = Setup();
        Assert.True(ctrl.SendToScratchpad(w1, "default"));
        Assert.Equal(WindowState.Scratchpad, host.Data[w1].State);
        Assert.True(host.Data[w1].InScratchpad);
        Assert.False(host.Data[w1].Visible);
        Assert.Equal(w1, ctrl.Scratchpads.Get("default"));
    }

    [Fact]
    public void ToggleScratchpad_SummonAndDismiss()
    {
        var (host, ctrl, w1, _, _) = Setup();
        ctrl.SendToScratchpad(w1, "default");

        // Summon.
        Assert.True(ctrl.ToggleScratchpad("default"));
        Assert.Equal(WindowState.Floating, host.Data[w1].State);
        Assert.True(host.Data[w1].Visible);

        // Dismiss.
        host.CurrentFocus = w1;
        Assert.True(ctrl.ToggleScratchpad("default"));
        Assert.Equal(WindowState.Scratchpad, host.Data[w1].State);
        Assert.False(host.Data[w1].Visible);
    }

    [Fact]
    public void ToggleScratchpad_EmptyPad_SpawnsWhenConfigured()
    {
        var cfg = new StateConfig
        {
            Scratchpad = new ScratchpadConfig
            {
                OnEmpty = "spawn",
                SpawnCommands = new Dictionary<string, string>
                {
                    ["term"] = "ghostty --class=aqueous-scratch-term",
                },
            },
        };
        var (host, ctrl, _, _, _) = Setup(cfg);
        Assert.False(ctrl.ToggleScratchpad("term"));   // empty → spawn, returns false (nothing to summon yet)
        Assert.Single(host.Spawned);
        Assert.Equal("ghostty --class=aqueous-scratch-term", host.Spawned[0]);
    }

    [Fact]
    public void SendToScratchpad_EvictsPriorOccupant()
    {
        var (host, ctrl, w1, w2, _) = Setup();
        ctrl.SendToScratchpad(w1, "default");
        ctrl.SendToScratchpad(w2, "default");
        Assert.Equal(WindowState.Tiled, host.Data[w1].State);   // demoted
        Assert.Equal(WindowState.Scratchpad, host.Data[w2].State);
        Assert.Equal(w2, ctrl.Scratchpads.Get("default"));
    }

    // ------- Lifecycle hooks ------------------------------------------

    [Fact]
    public void OnWindowDestroyed_ClearsFsSlotAndPad()
    {
        var (host, ctrl, w1, _, o1) = Setup();
        ctrl.ToggleFullscreen(w1);
        ctrl.OnWindowDestroyed(w1);
        Assert.Equal(WindowProxy.Zero, host.GetFullscreenWindow(o1));
    }

    [Fact]
    public void OnWorkspaceChanged_DemotesFullscreen()
    {
        var (host, ctrl, w1, _, o1) = Setup();
        ctrl.ToggleFullscreen(w1);
        ctrl.OnWorkspaceChanged(w1);
        Assert.Equal(WindowState.Tiled, host.Data[w1].State);
        Assert.Equal(WindowProxy.Zero, host.GetFullscreenWindow(o1));
    }

    // ------- TOML loader (B1e additions) -------------------------------

    [Fact]
    public void LayoutConfig_Parses_StateAndScratchpadSections()
    {
        const string toml = """
            [state]
            fullscreen_hides_bar = true
            maximize_full_output = false

            [scratchpad]
            on_empty = "spawn"
            width_frac = 0.7
            height_frac = 0.4
            anchor = "top"

            [scratchpad.spawn]
            term  = "ghostty"
            notes = "obsidian"
            """;
        var cfg = LayoutConfig.Parse(toml);
        Assert.True(cfg.State.FullscreenHidesBar);
        Assert.False(cfg.State.MaximizeFullOutput);
        Assert.Equal("spawn", cfg.State.Scratchpad.OnEmpty);
        Assert.Equal(0.7, cfg.State.Scratchpad.WidthFrac);
        Assert.Equal(0.4, cfg.State.Scratchpad.HeightFrac);
        Assert.Equal("top", cfg.State.Scratchpad.Anchor);
        Assert.Equal("ghostty", cfg.State.Scratchpad.SpawnCommands["term"]);
        Assert.Equal("obsidian", cfg.State.Scratchpad.SpawnCommands["notes"]);
    }

    [Fact]
    public void KeybindConfig_HasDefaultsForB1eActions()
    {
        var cfg = LayoutConfig.Parse("");
        Assert.Equal("Super+Shift+F", cfg.Keybinds.ChordsFor("toggle_fullscreen")[0]);
        Assert.Equal("Super+N", cfg.Keybinds.ChordsFor("toggle_minimize")[0]);
        Assert.Equal("Super+Shift+N", cfg.Keybinds.ChordsFor("unminimize_last")[0]);
        Assert.Equal("Super+Backslash", cfg.Keybinds.ChordsFor("toggle_scratchpad")[0]);
    }
}
