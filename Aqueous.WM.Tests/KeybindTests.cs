using Aqueous.WM.Features.Input;
using Aqueous.WM.Features.Layout;
using Xunit;

namespace Aqueous.WM.Tests;

public class KeybindTests
{
    // ---- KeyChord.Parse ----------------------------------------------

    [Fact]
    public void KeyChord_Parse_SimpleSuperLetter()
    {
        var c = KeyChord.Parse("Super+H");
        Assert.NotNull(c);
        Assert.Equal(64u, c!.Value.Modifiers); // ModSuper
        Assert.Equal((uint)'h', c.Value.Keysym);
    }

    [Fact]
    public void KeyChord_Parse_CaseInsensitive_Modifiers()
    {
        var c = KeyChord.Parse("super+shift+l");
        Assert.NotNull(c);
        Assert.Equal(64u | 1u, c!.Value.Modifiers); // Super + Shift
        Assert.Equal((uint)'l', c.Value.Keysym);
    }

    [Fact]
    public void KeyChord_Parse_FunctionKey()
    {
        var c = KeyChord.Parse("Ctrl+Alt+F1");
        Assert.NotNull(c);
        Assert.Equal(4u | 8u, c!.Value.Modifiers);
        Assert.Equal(0xffbeu, c.Value.Keysym); // F1
    }

    [Fact]
    public void KeyChord_Parse_NamedKeys()
    {
        Assert.Equal(0x002cu, KeyChord.Parse("Super+Comma")!.Value.Keysym);
        Assert.Equal(0xff0du, KeyChord.Parse("Super+Return")!.Value.Keysym);
        Assert.Equal(0xff09u, KeyChord.Parse("Super+Tab")!.Value.Keysym);
        Assert.Equal(0x0020u, KeyChord.Parse("Super+Space")!.Value.Keysym);
    }

    [Fact]
    public void KeyChord_Parse_Invalid_ReturnsNull()
    {
        Assert.Null(KeyChord.Parse(""));
        Assert.Null(KeyChord.Parse(null));
        Assert.Null(KeyChord.Parse("Super+"));
        Assert.Null(KeyChord.Parse("Super+NoSuchKey"));
        // two key tokens
        Assert.Null(KeyChord.Parse("H+L"));
    }

    // ---- KeybindConfig parsing ---------------------------------------

    [Fact]
    public void KeybindConfig_DefaultsWhenAbsent()
    {
        var cfg = LayoutConfig.Parse("[layout]\ndefault = \"tile\"\n");
        Assert.NotNull(cfg.Keybinds);
        // No overrides -> defaults are returned by ChordsFor.
        var chords = cfg.Keybinds.ChordsFor("focus_left");
        Assert.Single(chords);
        Assert.Equal("Super+H", chords[0]);
    }

    [Fact]
    public void KeybindConfig_OverrideSingleString()
    {
        const string toml = """
            [keybinds]
            cycle_focus = "Alt+Tab"
            """;
        var cfg = LayoutConfig.Parse(toml);
        Assert.Equal(new[] { "Alt+Tab" }, cfg.Keybinds.ChordsFor("cycle_focus"));
        // Other actions still fall back to defaults.
        Assert.Equal("Super+H", cfg.Keybinds.ChordsFor("focus_left")[0]);
    }

    [Fact]
    public void KeybindConfig_ArrayValueAndUnbind()
    {
        const string toml = """
            [keybinds]
            move_column_left = ["Super+Shift+H", "Super+BracketLeft"]
            cycle_focus = []
            """;
        var cfg = LayoutConfig.Parse(toml);
        var chords = cfg.Keybinds.ChordsFor("move_column_left");
        Assert.Equal(2, chords.Count);
        Assert.Equal("Super+Shift+H",   chords[0]);
        Assert.Equal("Super+BracketLeft", chords[1]);
        // Empty array = explicit unbind -> ChordsFor returns the empty list.
        Assert.Empty(cfg.Keybinds.ChordsFor("cycle_focus"));
    }

    [Fact]
    public void KeybindConfig_CustomChordTable()
    {
        const string toml = """
            [keybinds.custom]
            "Super+E"       = "spawn:nautilus"
            "Super+1"       = "set_layout:tile"
            "Super+2"       = "set_layout:scrolling"
            """;
        var cfg = LayoutConfig.Parse(toml);
        Assert.Equal("spawn:nautilus",     cfg.Keybinds.Custom["Super+E"]);
        Assert.Equal("set_layout:tile",    cfg.Keybinds.Custom["Super+1"]);
        Assert.Equal("set_layout:scrolling", cfg.Keybinds.Custom["Super+2"]);
    }

    [Fact]
    public void KeybindConfig_UnknownActionIgnored()
    {
        const string toml = """
            [keybinds]
            not_a_real_action = "Super+Z"
            focus_left = "Alt+H"
            """;
        var cfg = LayoutConfig.Parse(toml);
        // Unknown action does not appear in builtins.
        Assert.False(cfg.Keybinds.Builtins.ContainsKey("not_a_real_action"));
        // Known action still parsed.
        Assert.Equal("Alt+H", cfg.Keybinds.ChordsFor("focus_left")[0]);
    }

    // ---- LayoutController.SetLayout -----------------------------------

    [Fact]
    public void Controller_SetLayout_PromotesDefaultWhenNoOutputs()
    {
        var registry = new LayoutRegistry();
        var ctrl     = new LayoutController(registry, LayoutConfig.Default);
        long before = ctrl.Epoch;

        ctrl.SetLayout("scrolling");
        Assert.Equal(before + 1, ctrl.Epoch);
        Assert.Equal("scrolling", ctrl.ResolveLayoutId(new System.IntPtr(0xAA), null));
    }
}
