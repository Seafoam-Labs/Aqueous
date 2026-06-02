using Aqueous.Features.Configuration;

namespace Aqueous.Features.Input;

/// <summary>
/// Standalone parser for the <c>[input]</c> family of TOML-subset sections
/// (<c>[input]</c>, <c>[input.mouse]</c>, <c>[input.touchpad]</c>, <c>[input.trackpoint]</c>).
/// <para>
/// Extracted out of <see cref="Aqueous.Features.Layout.LayoutConfigLoader"/> so the input concern
/// owns its own parsing and <see cref="InputTomlReader"/> no longer has to round-trip a whole
/// <c>LayoutConfig</c> just to keep its <c>.Input</c>. The layout loader now delegates here.
/// </para>
/// <para>
/// Permissive by design: malformed values fall back to their per-key defaults, and any section or
/// key that is not input-related is ignored (forward-compatible). Defaults are seeded from
/// <see cref="InputConfig.Default"/> so an absent key keeps the default — this preserves the
/// "non-default wins" semantics relied upon by <see cref="InputTomlReader.Merge"/>.
/// </para>
/// </summary>
public static class InputConfigParser
{
    /// <summary>
    /// Parses the input-related sections from a TOML-subset document and returns the resulting
    /// <see cref="InputConfig"/>. Never throws; non-input content is skipped.
    /// </summary>
    public static InputConfig Parse(string text)
    {
        var inFocusFollowsMouse = InputConfig.Default.FocusFollowsMouse;
        var pointerAcceleration = InputConfig.Default.PointerAcceleration;
        var pointerAccelerationFactor = InputConfig.Default.PointerAccelerationFactor;
        string? inXkbLayout = InputConfig.Default.XkbLayout;
        string? inXkbVariant = InputConfig.Default.XkbVariant;
        string? inXkbOptions = InputConfig.Default.XkbOptions;

        var devMouse = new PerDeviceBuf();
        var devTouch = new PerDeviceBuf();
        var devTrack = new PerDeviceBuf();

        string? curSection = null;

        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith("#"))
            {
                continue;
            }

            // Array-of-tables ([[output]], [[exec]], …) — not input-related; clear the section so
            // their key/value lines are ignored until the next [section] header.
            if (line.StartsWith("[["))
            {
                curSection = null;
                continue;
            }

            if (line.StartsWith("["))
            {
                int end = line.IndexOf(']');
                curSection = end > 1 ? line.Substring(1, end - 1).Trim() : line;
                continue;
            }

            int eq = line.IndexOf('=');
            if (eq <= 0)
            {
                continue;
            }

            var key = line.Substring(0, eq).Trim();
            var valRaw = line.Substring(eq + 1).Trim();
            // Strip trailing inline comment (#).
            int hash = TomlScalars.IndexOfUnquoted(valRaw, '#');
            if (hash >= 0)
            {
                valRaw = valRaw.Substring(0, hash).Trim();
            }

            var val = TomlScalars.StripQuotes(valRaw);

            switch (curSection)
            {
                case "input":
                    switch (key)
                    {
                        case "focus_follows_mouse":
                            inFocusFollowsMouse = TomlScalars.ParseBool(val, inFocusFollowsMouse);
                            break;
                        case "pointer_acceleration":
                            pointerAcceleration = TomlScalars.ParseBool(val, pointerAcceleration);
                            break;
                        case "pointer_acceleration_factor":
                            pointerAccelerationFactor = TomlScalars.ParseDouble(val, pointerAccelerationFactor);
                            break;
                        case "xkb_layout":
                            inXkbLayout = TomlScalars.StripQuotes(val);
                            break;
                        case "xkb_variant":
                            inXkbVariant = TomlScalars.StripQuotes(val);
                            break;
                        case "xkb_options":
                            inXkbOptions = TomlScalars.StripQuotes(val);
                            break;
                    }

                    break;
                case "input.mouse": ParseDeviceKey(devMouse, key, val); break;
                case "input.touchpad": ParseDeviceKey(devTouch, key, val); break;
                case "input.trackpoint": ParseDeviceKey(devTrack, key, val); break;
            }
        }

        return new InputConfig
        {
            FocusFollowsMouse = inFocusFollowsMouse,
            PointerAcceleration = pointerAcceleration,
            PointerAccelerationFactor = pointerAccelerationFactor,
            Mouse = devMouse.ToRecord(),
            Touchpad = devTouch.ToRecord(),
            Trackpoint = devTrack.ToRecord(),
            XkbLayout = inXkbLayout,
            XkbVariant = inXkbVariant,
            XkbOptions = inXkbOptions,
        };
    }

    /// <summary>
    /// Mutable scratch buffer that mirrors <see cref="PerDeviceInput"/>'s nullable fields. Used while
    /// parsing <c>[input.mouse|touchpad|trackpoint]</c> sub-tables, then frozen via <see
    /// cref="ToRecord"/>.
    /// </summary>
    private sealed class PerDeviceBuf
    {
        public string? AccelProfile;
        public double? AccelSpeed;
        public bool? NaturalScroll;
        public bool? Tap;
        public bool? Dwt;
        public bool? LeftHanded;
        public string? ClickMethod;
        public string? ScrollMethod;
        public bool? MiddleEmulation;

        public PerDeviceInput ToRecord() => new()
        {
            AccelProfile = AccelProfile,
            AccelSpeed = AccelSpeed,
            NaturalScroll = NaturalScroll,
            Tap = Tap,
            Dwt = Dwt,
            LeftHanded = LeftHanded,
            ClickMethod = ClickMethod,
            ScrollMethod = ScrollMethod,
            MiddleEmulation = MiddleEmulation,
        };
    }

    /// <summary>
    /// Maps one <c>key = value</c> from an <c>[input.&lt;device&gt;]</c> sub-table onto <paramref
    /// name="d"/>. Key names mirror niri's KDL schema (with <c>-</c> normalised to <c>_</c>) so
    /// configs port trivially.
    /// </summary>
    private static void ParseDeviceKey(PerDeviceBuf d, string key, string val)
    {
        // Accept both "accel-speed" and "accel_speed" — niri uses dashes, most TOML tooling prefers
        // underscores.
        var k = key.Replace('-', '_');
        var v = TomlScalars.StripQuotes(val);
        switch (k)
        {
            case "accel_profile":
                d.AccelProfile = v;
                break;
            case "accel_speed":
                d.AccelSpeed = TomlScalars.ParseDouble(val, 0.0);
                break;
            case "natural_scroll":
                d.NaturalScroll = TomlScalars.ParseBool(val, false);
                break;
            case "tap":
                d.Tap = TomlScalars.ParseBool(val, false);
                break;
            case "dwt":
                d.Dwt = TomlScalars.ParseBool(val, false);
                break;
            case "left_handed":
                d.LeftHanded = TomlScalars.ParseBool(val, false);
                break;
            case "click_method":
                d.ClickMethod = v;
                break;
            case "scroll_method":
                d.ScrollMethod = v;
                break;
            case "middle_emulation":
                d.MiddleEmulation = TomlScalars.ParseBool(val, false);
                break;
        }
    }
}
