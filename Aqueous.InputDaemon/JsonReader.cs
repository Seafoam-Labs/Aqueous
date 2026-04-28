using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace Aqueous.InputDaemon;

/// <summary>
/// Minimal JSON reader for the daemon's <c>apply</c> request shape only.
/// Hand-rolled to keep the daemon AOT-friendly without
/// <c>System.Text.Json</c>'s reflection paths or source-gen tooling.
/// Accepts: objects, strings, numbers (double), booleans, null.
/// Returns nested <c>Dictionary&lt;string, object?&gt;</c>.
/// </summary>
internal static class JsonReader
{
    public static Dictionary<string, object?>? ParseObject(string text)
    {
        int i = 0;
        SkipWs(text, ref i);
        if (i >= text.Length || text[i] != '{') return null;
        return ReadObject(text, ref i);
    }

    private static Dictionary<string, object?> ReadObject(string s, ref int i)
    {
        var d = new Dictionary<string, object?>(StringComparer.Ordinal);
        i++; // consume '{'
        SkipWs(s, ref i);
        if (i < s.Length && s[i] == '}') { i++; return d; }
        while (i < s.Length)
        {
            SkipWs(s, ref i);
            var key = ReadString(s, ref i);
            SkipWs(s, ref i);
            if (i >= s.Length || s[i] != ':') throw new FormatException("expected ':'");
            i++;
            SkipWs(s, ref i);
            var val = ReadValue(s, ref i);
            d[key] = val;
            SkipWs(s, ref i);
            if (i < s.Length && s[i] == ',') { i++; continue; }
            if (i < s.Length && s[i] == '}') { i++; return d; }
            throw new FormatException("expected ',' or '}'");
        }
        throw new FormatException("unterminated object");
    }

    private static object? ReadValue(string s, ref int i)
    {
        SkipWs(s, ref i);
        if (i >= s.Length) throw new FormatException("unexpected eof");
        char c = s[i];
        if (c == '{') return ReadObject(s, ref i);
        if (c == '"') return ReadString(s, ref i);
        if (c == 't' || c == 'f') return ReadBool(s, ref i);
        if (c == 'n') { ExpectLiteral(s, ref i, "null"); return null; }
        return ReadNumber(s, ref i);
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
        if (i + lit.Length > s.Length || s.AsSpan(i, lit.Length).SequenceEqual(lit) == false)
            throw new FormatException("expected " + lit);
        i += lit.Length;
    }

    private static void SkipWs(string s, ref int i)
    {
        while (i < s.Length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++;
    }
}
