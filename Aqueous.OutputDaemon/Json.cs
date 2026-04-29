using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace Aqueous.OutputDaemon;

/// <summary>
/// Minimal hand-rolled JSON reader/writer.
/// AOT-friendly (no reflection, no source-gen). Accepts objects, arrays,
/// strings, numbers (double), booleans, null. Returns nested
/// <see cref="Dictionary{TKey,TValue}"/> / <see cref="List{T}"/> trees.
/// Mirrors the InputDaemon's <c>JsonReader</c>, plus array support — needed
/// because <c>wlr-randr --json</c> emits a top-level JSON array.
/// </summary>
internal static class Json
{
    // ---- Reader -------------------------------------------------------

    public static object? Parse(string text)
    {
        int i = 0;
        SkipWs(text, ref i);
        if (i >= text.Length) return null;
        var v = ReadValue(text, ref i);
        return v;
    }

    public static Dictionary<string, object?>? ParseObject(string text)
        => Parse(text) as Dictionary<string, object?>;

    public static List<object?>? ParseArray(string text)
        => Parse(text) as List<object?>;

    private static object? ReadValue(string s, ref int i)
    {
        SkipWs(s, ref i);
        if (i >= s.Length) throw new FormatException("unexpected eof");
        char c = s[i];
        if (c == '{') return ReadObject(s, ref i);
        if (c == '[') return ReadArray(s, ref i);
        if (c == '"') return ReadString(s, ref i);
        if (c == 't' || c == 'f') return ReadBool(s, ref i);
        if (c == 'n') { ExpectLiteral(s, ref i, "null"); return null; }
        return ReadNumber(s, ref i);
    }

    private static Dictionary<string, object?> ReadObject(string s, ref int i)
    {
        var d = new Dictionary<string, object?>(StringComparer.Ordinal);
        i++; // '{'
        SkipWs(s, ref i);
        if (i < s.Length && s[i] == '}') { i++; return d; }
        while (i < s.Length)
        {
            SkipWs(s, ref i);
            var key = ReadString(s, ref i);
            SkipWs(s, ref i);
            if (i >= s.Length || s[i] != ':') throw new FormatException("expected ':'");
            i++;
            d[key] = ReadValue(s, ref i);
            SkipWs(s, ref i);
            if (i < s.Length && s[i] == ',') { i++; continue; }
            if (i < s.Length && s[i] == '}') { i++; return d; }
            throw new FormatException("expected ',' or '}'");
        }
        throw new FormatException("unterminated object");
    }

    private static List<object?> ReadArray(string s, ref int i)
    {
        var l = new List<object?>();
        i++; // '['
        SkipWs(s, ref i);
        if (i < s.Length && s[i] == ']') { i++; return l; }
        while (i < s.Length)
        {
            l.Add(ReadValue(s, ref i));
            SkipWs(s, ref i);
            if (i < s.Length && s[i] == ',') { i++; SkipWs(s, ref i); continue; }
            if (i < s.Length && s[i] == ']') { i++; return l; }
            throw new FormatException("expected ',' or ']'");
        }
        throw new FormatException("unterminated array");
    }

    private static string ReadString(string s, ref int i)
    {
        if (s[i] != '"') throw new FormatException("expected string");
        i++;
        var sb = new StringBuilder();
        while (i < s.Length)
        {
            char c = s[i++];
            if (c == '"') return sb.ToString();
            if (c == '\\')
            {
                if (i >= s.Length) throw new FormatException("bad escape");
                char e = s[i++];
                switch (e)
                {
                    case '"': sb.Append('"'); break;
                    case '\\': sb.Append('\\'); break;
                    case '/': sb.Append('/'); break;
                    case 'n': sb.Append('\n'); break;
                    case 'r': sb.Append('\r'); break;
                    case 't': sb.Append('\t'); break;
                    case 'b': sb.Append('\b'); break;
                    case 'f': sb.Append('\f'); break;
                    case 'u':
                        if (i + 4 > s.Length) throw new FormatException("bad \\u");
                        sb.Append((char)int.Parse(s.AsSpan(i, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
                        i += 4;
                        break;
                    default: throw new FormatException("bad escape \\" + e);
                }
            }
            else sb.Append(c);
        }
        throw new FormatException("unterminated string");
    }

    private static bool ReadBool(string s, ref int i)
    {
        if (s[i] == 't') { ExpectLiteral(s, ref i, "true"); return true; }
        ExpectLiteral(s, ref i, "false");
        return false;
    }

    private static double ReadNumber(string s, ref int i)
    {
        int start = i;
        if (s[i] == '-' || s[i] == '+') i++;
        while (i < s.Length && (char.IsDigit(s[i]) || s[i] == '.' || s[i] == 'e' || s[i] == 'E' || s[i] == '-' || s[i] == '+'))
            i++;
        return double.Parse(s.AsSpan(start, i - start), NumberStyles.Float, CultureInfo.InvariantCulture);
    }

    private static void ExpectLiteral(string s, ref int i, string lit)
    {
        if (i + lit.Length > s.Length || !s.AsSpan(i, lit.Length).SequenceEqual(lit))
            throw new FormatException("expected " + lit);
        i += lit.Length;
    }

    private static void SkipWs(string s, ref int i)
    {
        while (i < s.Length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++;
    }

    // ---- Writer -------------------------------------------------------

    public static string Write(object? v)
    {
        var sb = new StringBuilder();
        WriteValue(sb, v);
        return sb.ToString();
    }

    private static void WriteValue(StringBuilder sb, object? v)
    {
        switch (v)
        {
            case null: sb.Append("null"); break;
            case bool b: sb.Append(b ? "true" : "false"); break;
            case string s: WriteString(sb, s); break;
            case int i: sb.Append(i.ToString(CultureInfo.InvariantCulture)); break;
            case long l: sb.Append(l.ToString(CultureInfo.InvariantCulture)); break;
            case double d: sb.Append(d.ToString("R", CultureInfo.InvariantCulture)); break;
            case IDictionary<string, object?> obj:
                sb.Append('{');
                bool first = true;
                foreach (var kv in obj)
                {
                    if (!first) sb.Append(',');
                    first = false;
                    WriteString(sb, kv.Key);
                    sb.Append(':');
                    WriteValue(sb, kv.Value);
                }
                sb.Append('}');
                break;
            case System.Collections.IEnumerable arr:
                sb.Append('[');
                bool firstA = true;
                foreach (var item in arr)
                {
                    if (!firstA) sb.Append(',');
                    firstA = false;
                    WriteValue(sb, item);
                }
                sb.Append(']');
                break;
            default:
                WriteString(sb, v.ToString() ?? "");
                break;
        }
    }

    private static void WriteString(StringBuilder sb, string s)
    {
        sb.Append('"');
        foreach (char c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                default:
                    if (c < 0x20)
                        sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else
                        sb.Append(c);
                    break;
            }
        }
        sb.Append('"');
    }
}
