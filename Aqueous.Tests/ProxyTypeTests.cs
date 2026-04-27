using System;
using System.Collections.Generic;
using Aqueous.Features.State;
using Xunit;

namespace Aqueous.Tests;

/// <summary>
/// Phase 2 / Step 8.B.6 — covers the proxy value-type semantics
/// introduced to keep window/output/seat handles type-distinct across
/// the WM ↔ window-state-controller seam.
/// </summary>
public class ProxyTypeTests
{
    // --- WindowProxy ----------------------------------------------------

    [Fact]
    public void WindowProxy_Zero_IsZero()
    {
        Assert.True(WindowProxy.Zero.IsZero);
        Assert.Equal(IntPtr.Zero, WindowProxy.Zero.Handle);
    }

    [Fact]
    public void WindowProxy_NonZero_IsNotZero()
    {
        var p = new WindowProxy(new IntPtr(0x1234));
        Assert.False(p.IsZero);
        Assert.Equal(new IntPtr(0x1234), p.Handle);
    }

    [Fact]
    public void WindowProxy_ValueEquality()
    {
        var a = new WindowProxy(new IntPtr(0x42));
        var b = new WindowProxy(new IntPtr(0x42));
        var c = new WindowProxy(new IntPtr(0x43));

        Assert.Equal(a, b);
        Assert.True(a == b);
        Assert.False(a == c);
        Assert.NotEqual(a, c);
        Assert.Equal(a.GetHashCode(), b.GetHashCode());
    }

    [Fact]
    public void WindowProxy_DictionaryKey_BehavesLikeValueType()
    {
        var dict = new Dictionary<WindowProxy, string>
        {
            [new WindowProxy(new IntPtr(0xA1))] = "alpha",
            [new WindowProxy(new IntPtr(0xB2))] = "beta",
        };

        Assert.Equal("alpha", dict[new WindowProxy(new IntPtr(0xA1))]);
        Assert.Equal("beta", dict[new WindowProxy(new IntPtr(0xB2))]);
        Assert.False(dict.ContainsKey(new WindowProxy(new IntPtr(0xC3))));
    }

    // --- OutputProxy ----------------------------------------------------

    [Fact]
    public void OutputProxy_Zero_IsZero()
    {
        Assert.True(OutputProxy.Zero.IsZero);
    }

    [Fact]
    public void OutputProxy_ValueEquality()
    {
        var a = new OutputProxy(new IntPtr(0xA1));
        var b = new OutputProxy(new IntPtr(0xA1));
        Assert.Equal(a, b);
        Assert.Equal(a.GetHashCode(), b.GetHashCode());
    }

    // --- SeatProxy ------------------------------------------------------

    [Fact]
    public void SeatProxy_Zero_IsZero()
    {
        Assert.True(SeatProxy.Zero.IsZero);
    }

    [Fact]
    public void SeatProxy_ValueEquality()
    {
        var a = new SeatProxy(new IntPtr(0xC0FFEE));
        var b = new SeatProxy(new IntPtr(0xC0FFEE));
        Assert.Equal(a, b);
    }

    // --- Type-distinctness ---------------------------------------------
    // The whole point of having three structs rather than one is that the
    // compiler refuses to interchange them. A handle-shaped type-mismatch
    // bug is now caught at compile time. This test documents that — if it
    // ever stops failing to compile, someone collapsed the three structs.

    [Fact]
    public void Proxies_Carry_Distinct_Identities()
    {
        // Same underlying IntPtr value but different proxy types.
        var win = new WindowProxy(new IntPtr(0x1));
        var output = new OutputProxy(new IntPtr(0x1));
        var seat = new SeatProxy(new IntPtr(0x1));

        // Each carries the same raw handle …
        Assert.Equal(win.Handle, output.Handle);
        Assert.Equal(win.Handle, seat.Handle);

        // … but they are distinct types, so dictionaries are not
        // accidentally interchangeable.
        var winDict = new Dictionary<WindowProxy, int> { [win] = 1 };
        var outDict = new Dictionary<OutputProxy, int> { [output] = 2 };
        var seatDict = new Dictionary<SeatProxy, int> { [seat] = 3 };

        Assert.Equal(1, winDict[win]);
        Assert.Equal(2, outDict[output]);
        Assert.Equal(3, seatDict[seat]);
    }

    // --- ToString -------------------------------------------------------

    [Fact]
    public void Proxies_ToString_ContainsHexHandle()
    {
        Assert.Contains("0x42", new WindowProxy(new IntPtr(0x42)).ToString());
        Assert.Contains("0xa1", new OutputProxy(new IntPtr(0xA1)).ToString());
        Assert.Contains("0xc0ffee", new SeatProxy(new IntPtr(0xC0FFEE)).ToString());
    }
}
