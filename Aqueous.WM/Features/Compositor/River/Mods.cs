using System;

namespace Aqueous.Features.Compositor.River
{
    /// <summary>
    /// Primary modifier used for Aqueous.WM interactive bindings
    /// (pointer drag / resize, key bindings like Super+Q, etc.).
    ///
    /// Selection is driven by the <c>AQUEOUS_MOD</c> environment variable,
    /// which <c>launch_river.sh</c> sets to <c>Alt</c> when running nested
    /// inside another Wayland/X session (so the host compositor doesn't eat
    /// Super) and to <c>Super</c> on a real TTY. Defaults to Super.
    /// </summary>
    public static class Mods
    {
        // river_window_management_v1 seat_v1.modifiers bitfield values.
        // See river-window-management-v1.xml: shift=1, caps=2, ctrl=4,
        // mod1/alt=8, mod2=16, mod3=32, mod4/super/logo=64, mod5=128.
        public const uint ModShift = 1;
        public const uint ModCtrl  = 4;
        public const uint ModAlt   = 8;   // mod1
        public const uint ModSuper = 64;  // mod4

        // XKB keysyms.
        public const uint KeySuperL = 0xffeb;
        public const uint KeyAltL   = 0xffe9;

        public enum Kind { Super, Alt }

        public static Kind Primary { get; } =
            (Environment.GetEnvironmentVariable("AQUEOUS_MOD") ?? "")
                .Trim().ToLowerInvariant() switch
            {
                "alt"   => Kind.Alt,
                "super" => Kind.Super,
                ""      => Kind.Super,
                _       => Kind.Super,
            };

        /// <summary>Bitmask for the river modifiers field.</summary>
        public static uint PrimaryMask => Primary == Kind.Alt ? ModAlt : ModSuper;

        /// <summary>XKB keysym for the left-hand physical key of the primary modifier.</summary>
        public static uint PrimaryKeysym => Primary == Kind.Alt ? KeyAltL : KeySuperL;

        public static string PrimaryName => Primary == Kind.Alt ? "Alt" : "Super";
    }
}
