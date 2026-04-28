using System.Globalization;
using System.Text;

namespace Aqueous.Features.Input;

/// <summary>
/// Wire format between Aqueous (WM client) and <c>aqueous-inputd</c>
/// (privileged libinput sidecar). One JSON object per line; the daemon
/// answers with a single-line JSON ack. The schema is intentionally
/// flat and hand-serialised — the daemon ships AOT and we don't want
/// to drag in <c>System.Text.Json</c>'s reflection-based fallback.
/// </summary>
internal static class InputDaemonProtocol
{
    /// <summary>
    /// Path to the per-user UDS the daemon listens on. Lives under
    /// <c>$XDG_RUNTIME_DIR</c> so it inherits the directory's <c>0700</c>
    /// permissions and is automatically cleaned up on logout.
    /// </summary>
    public static string SocketPath()
    {
        var rt = System.Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
        if (string.IsNullOrEmpty(rt))
        {
            rt = "/tmp";
        }
        return System.IO.Path.Combine(rt, "aqueous-inputd.sock");
    }

    /// <summary>Serialise an <see cref="InputConfig"/> as a single-line
    /// <c>apply</c> request. Caller appends <c>'\n'</c>.</summary>
    public static string SerializeApply(InputConfig cfg)
    {
        var sb = new StringBuilder(512);
        sb.Append("{\"kind\":\"apply\",");
        sb.Append("\"mouse\":");
        AppendDevice(sb, EffectiveMouse(cfg));
        sb.Append(",\"touchpad\":");
        AppendDevice(sb, cfg.Touchpad);
        sb.Append(",\"trackpoint\":");
        AppendDevice(sb, cfg.Trackpoint);
        sb.Append('}');
        return sb.ToString();
    }

    /// <summary>
    /// Apply the legacy flat keys (<c>pointer_acceleration</c>,
    /// <c>pointer_acceleration_factor</c>) onto the per-device mouse
    /// config when the dedicated <c>[input.mouse]</c> sub-table didn't
    /// override them. Keeps backwards compatibility.
    /// </summary>
    private static PerDeviceInput EffectiveMouse(InputConfig cfg)
    {
        var m = cfg.Mouse;
        var profile = m.AccelProfile ?? (cfg.PointerAcceleration ? "adaptive" : "flat");
        var speed   = m.AccelSpeed   ?? cfg.PointerAccelerationFactor;
        return m with { AccelProfile = profile, AccelSpeed = speed };
    }

    private static void AppendDevice(StringBuilder sb, PerDeviceInput d)
    {
        sb.Append('{');
        bool first = true;
        AppendStr(sb, ref first, "accel_profile", d.AccelProfile);
        AppendDbl(sb, ref first, "accel_speed", d.AccelSpeed);
        AppendBool(sb, ref first, "natural_scroll", d.NaturalScroll);
        AppendBool(sb, ref first, "tap", d.Tap);
        AppendBool(sb, ref first, "dwt", d.Dwt);
        AppendBool(sb, ref first, "left_handed", d.LeftHanded);
        AppendStr(sb, ref first, "click_method", d.ClickMethod);
        AppendStr(sb, ref first, "scroll_method", d.ScrollMethod);
        AppendBool(sb, ref first, "middle_emulation", d.MiddleEmulation);
        sb.Append('}');
    }

    private static void AppendStr(StringBuilder sb, ref bool first, string k, string? v)
    {
        if (v is null) return;
        Sep(sb, ref first);
        sb.Append('"').Append(k).Append("\":\"").Append(EscapeJson(v)).Append('"');
    }

    private static void AppendBool(StringBuilder sb, ref bool first, string k, bool? v)
    {
        if (v is null) return;
        Sep(sb, ref first);
        sb.Append('"').Append(k).Append("\":").Append(v.Value ? "true" : "false");
    }

    private static void AppendDbl(StringBuilder sb, ref bool first, string k, double? v)
    {
        if (v is null) return;
        Sep(sb, ref first);
        sb.Append('"').Append(k).Append("\":")
            .Append(v.Value.ToString("0.######", CultureInfo.InvariantCulture));
    }

    private static void Sep(StringBuilder sb, ref bool first)
    {
        if (!first) sb.Append(',');
        first = false;
    }

    private static string EscapeJson(string s)
    {
        var sb = new StringBuilder(s.Length + 4);
        foreach (var c in s)
        {
            switch (c)
            {
                case '"':  sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n");  break;
                case '\r': sb.Append("\\r");  break;
                case '\t': sb.Append("\\t");  break;
                default:
                    if (c < 0x20)
                        sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else
                        sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }
}
