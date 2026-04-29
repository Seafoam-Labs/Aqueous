using System;
using System.Collections.Generic;
using Aqueous.OutputDaemon;
using Xunit;

namespace Aqueous.OutputDaemon.Tests;

public class JsonTests
{
    [Fact]
    public void Parse_object_basic()
    {
        var d = Json.ParseObject("{\"a\":1,\"b\":\"x\",\"c\":true,\"d\":null}");
        Assert.NotNull(d);
        Assert.Equal(1.0, (double)d!["a"]!);
        Assert.Equal("x", d["b"]);
        Assert.Equal(true, d["c"]);
        Assert.Null(d["d"]);
    }

    [Fact]
    public void Parse_nested_array_of_objects()
    {
        var arr = Json.ParseArray("[{\"k\":1},{\"k\":2}]");
        Assert.NotNull(arr);
        Assert.Equal(2, arr!.Count);
        Assert.Equal(1.0, (double)((Dictionary<string, object?>)arr[0]!)["k"]!);
    }

    [Fact]
    public void Parse_handles_escapes()
    {
        var d = Json.ParseObject("{\"s\":\"a\\nb\\tc\\\"d\\\\e\"}");
        Assert.Equal("a\nb\tc\"d\\e", d!["s"]);
    }

    [Fact]
    public void Parse_handles_unicode_escape()
    {
        var d = Json.ParseObject("{\"s\":\"\\u00e9\"}");
        Assert.Equal("\u00e9", d!["s"]);
    }

    [Fact]
    public void Parse_bad_input_throws()
    {
        Assert.Throws<FormatException>(() => Json.ParseObject("{\"a\":"));
        Assert.Throws<FormatException>(() => Json.ParseObject("{\"a\":\"b\""));
    }

    [Fact]
    public void Parse_non_object_returns_null_for_array()
    {
        // ParseObject only succeeds on '{' input; arrays return null.
        Assert.Null(Json.ParseObject("[1,2,3]"));
    }

    [Fact]
    public void Write_roundtrip_object()
    {
        var src = new Dictionary<string, object?>
        {
            ["ok"] = true,
            ["n"] = 42.0,
            ["s"] = "hello\nworld",
            ["arr"] = new List<object?> { 1.0, 2.0, "three" },
            ["nested"] = new Dictionary<string, object?> { ["x"] = false },
            ["nil"] = null,
        };
        var s = Json.Write(src);
        var back = Json.ParseObject(s);
        Assert.NotNull(back);
        Assert.Equal(true, back!["ok"]);
        Assert.Equal(42.0, (double)back["n"]!);
        Assert.Equal("hello\nworld", back["s"]);
        Assert.Equal(3, ((List<object?>)back["arr"]!).Count);
        Assert.Equal(false, ((Dictionary<string, object?>)back["nested"]!)["x"]);
        Assert.Null(back["nil"]);
    }

    [Fact]
    public void Write_escapes_quotes_and_backslashes()
    {
        var s = Json.Write(new Dictionary<string, object?> { ["k"] = "a\"b\\c" });
        Assert.Contains("\\\"", s);
        Assert.Contains("\\\\", s);
    }
}
