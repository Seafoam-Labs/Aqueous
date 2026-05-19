using System;
using System.Runtime.InteropServices;
using System.Text;
using Aqueous.Features.Compositor.River.Dispatch;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch;

/// <summary>
/// Unit tests for <see cref="WlArgumentDecoder"/>: synthesize a
/// <c>wl_argument</c> array in unmanaged memory, point a
/// <see cref="WlEvent"/> at it, and assert each accessor reads back the
/// value we wrote. Pure pointer-arithmetic — no libwayland involved.
/// </summary>
public sealed unsafe class WlArgumentDecoderTests
{
    /// <summary>
    /// Allocate a 6-slot pointer-sized array, populate it with one
    /// value of every kind, and verify every accessor returns the
    /// matching value.
    /// </summary>
    [Fact]
    public void Decodes_int_uint_fixed_object_array_and_fd_slots()
    {
        int slotCount = 6;
        IntPtr block = Marshal.AllocHGlobal(slotCount * sizeof(nint));
        try
        {
            nint* slots = (nint*)block;

            // 0: int (signed)
            *(int*)(slots + 0) = -1234;
            // 1: uint
            *(uint*)(slots + 1) = 0xDEADBEEFu;
            // 2: fixed (24.8 -> 1.5 == 384)
            *(int*)(slots + 2) = 384;
            // 3: object handle
            *(IntPtr*)(slots + 3) = new IntPtr(0xCAFE);
            // 4: array pointer
            *(IntPtr*)(slots + 4) = new IntPtr(0xABCD);
            // 5: fd (= int)
            *(int*)(slots + 5) = 42;

            Assert.Equal(-1234, WlArgumentDecoder.GetInt(block, 0));
            Assert.Equal(0xDEADBEEFu, WlArgumentDecoder.GetUInt(block, 1));
            Assert.Equal(384, WlArgumentDecoder.GetFixed(block, 2));
            Assert.Equal(1.5, WlArgumentDecoder.FixedToDouble(384));
            Assert.Equal(new IntPtr(0xCAFE), WlArgumentDecoder.GetObject(block, 3));
            Assert.Equal(new IntPtr(0xABCD), WlArgumentDecoder.GetArrayPtr(block, 4));
            Assert.Equal(42, WlArgumentDecoder.GetFd(block, 5));
        }
        finally
        {
            Marshal.FreeHGlobal(block);
        }
    }

    /// <summary>
    /// String marshalling: write a NUL-terminated UTF-8 string into
    /// unmanaged memory, store its pointer in a slot, and verify both
    /// the raw-pointer and managed-string accessors.
    /// </summary>
    [Fact]
    public void Decodes_string_slot_via_PtrToStringUTF8()
    {
        const string expected = "hello, wl_seat";
        var bytes = Encoding.UTF8.GetBytes(expected);
        IntPtr str = Marshal.AllocHGlobal(bytes.Length + 1);
        Marshal.Copy(bytes, 0, str, bytes.Length);
        Marshal.WriteByte(str, bytes.Length, 0);

        IntPtr block = Marshal.AllocHGlobal(sizeof(nint));
        try
        {
            *(IntPtr*)block = str;

            Assert.Equal(str, WlArgumentDecoder.GetStringPtr(block, 0));
            Assert.Equal(expected, WlArgumentDecoder.GetString(block, 0));
        }
        finally
        {
            Marshal.FreeHGlobal(block);
            Marshal.FreeHGlobal(str);
        }
    }

    /// <summary>NULL string slot decodes as managed <c>null</c>.</summary>
    [Fact]
    public void Null_string_slot_decodes_as_null()
    {
        IntPtr block = Marshal.AllocHGlobal(sizeof(nint));
        try
        {
            *(IntPtr*)block = IntPtr.Zero;
            Assert.Null(WlArgumentDecoder.GetString(block, 0));
            Assert.Equal(IntPtr.Zero, WlArgumentDecoder.GetStringPtr(block, 0));
        }
        finally
        {
            Marshal.FreeHGlobal(block);
        }
    }

    /// <summary>
    /// <see cref="WlArgumentDecoder.SlotSize"/> matches the platform
    /// pointer width — pinned at 8 on the targeted 64-bit Linux.
    /// </summary>
    [Fact]
    public void SlotSize_equals_pointer_size()
    {
        Assert.Equal(IntPtr.Size, WlArgumentDecoder.SlotSize);
    }

    /// <summary>
    /// <see cref="WlArgumentDecoder.FixedToDouble"/> round-trips
    /// known 24.8 values.
    /// </summary>
    [Theory]
    [InlineData(0, 0.0)]
    [InlineData(256, 1.0)]
    [InlineData(-256, -1.0)]
    [InlineData(128, 0.5)]
    [InlineData(384, 1.5)]
    public void FixedToDouble_converts_24_8_fixed_point(int raw, double expected)
    {
        Assert.Equal(expected, WlArgumentDecoder.FixedToDouble(raw));
    }
}
