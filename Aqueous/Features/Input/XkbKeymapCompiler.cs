using System;
using System.Runtime.InteropServices;
using System.Text;
using Aqueous.Diagnostics;

namespace Aqueous.Features.Input;

/// <summary>
/// Compiles an xkbcommon keymap from the <c>[input] xkb_layout/xkb_variant/xkb_options</c> values in
/// <c>wm.toml</c> and materialises it into a sealed, read-only memory file descriptor suitable for
/// the <c>river_xkb_config_v1.create_keymap(new_id, fd, format)</c> request.
/// <para>
/// The compositor <c>fstat</c>s the fd to learn the size and <c>mmap</c>s <c>size - 1</c> with
/// <c>MAP_PRIVATE</c>, so the written buffer is the <c>XKB_KEYMAP_FORMAT_TEXT_V1</c> string plus a
/// trailing NUL terminator (size = <c>strlen + 1</c>). Compilation failures are logged and surfaced
/// as a <c>false</c> result rather than throwing — mirroring the compositor's defensive style.
/// </para>
/// </summary>
internal static partial class XkbKeymapCompiler
{
    private const string XkbLib = "libxkbcommon.so.0";
    private const string CLib = "libc";

    // XKB_KEYMAP_FORMAT_TEXT_V1
    private const int XkbKeymapFormatTextV1 = 1;

    // memfd_create flags.
    private const uint MFD_CLOEXEC = 0x0001;
    private const uint MFD_ALLOW_SEALING = 0x0002;

    // fcntl seal command + seal bits (linux/fcntl.h).
    private const int F_ADD_SEALS = 1033;
    private const int F_SEAL_SHRINK = 0x0002;
    private const int F_SEAL_WRITE = 0x0008;

    [StructLayout(LayoutKind.Sequential)]
    private struct XkbRuleNames
    {
        public IntPtr rules;
        public IntPtr model;
        public IntPtr layout;
        public IntPtr variant;
        public IntPtr options;
    }

    [LibraryImport(XkbLib)] private static partial IntPtr xkb_context_new(int flags);
    [LibraryImport(XkbLib)] private static partial void xkb_context_unref(IntPtr context);
    [LibraryImport(XkbLib)] private static partial IntPtr xkb_keymap_new_from_names(IntPtr context, ref XkbRuleNames names, int flags);
    [LibraryImport(XkbLib)] private static partial void xkb_keymap_unref(IntPtr keymap);
    [LibraryImport(XkbLib)] private static partial IntPtr xkb_keymap_get_as_string(IntPtr keymap, int format);

    [LibraryImport(CLib, StringMarshalling = StringMarshalling.Utf8, SetLastError = true)]
    private static partial int memfd_create(string name, uint flags);

    [LibraryImport(CLib, SetLastError = true)]
    private static partial nint write(int fd, IntPtr buf, nuint count);

    [LibraryImport(CLib, SetLastError = true)]
    private static partial int fcntl(int fd, int cmd, int arg);

    [LibraryImport(CLib, SetLastError = true)]
    private static partial int close(int fd);

    [LibraryImport(CLib)]
    private static partial void free(IntPtr ptr);

    /// <summary>
    /// Compiles the keymap and writes it to a fresh sealed memfd.
    /// </summary>
    /// <param name="config">Input configuration carrying the xkb_* fields.</param>
    /// <param name="fd">On success, an owned file descriptor positioned with the keymap data; the
    /// caller must <c>close</c> it once the <c>create_keymap</c> request has been marshalled.</param>
    /// <returns><c>true</c> if a keymap was compiled and written; <c>false</c> on any failure.</returns>
    public static bool TryCompileToFd(InputConfig config, out int fd)
    {
        fd = -1;
        IntPtr ctx = IntPtr.Zero;
        IntPtr keymap = IntPtr.Zero;
        IntPtr keymapStr = IntPtr.Zero;

        // Native UTF-8 buffers for the rule_names fields; null when the corresponding value is unset
        // so xkbcommon falls back to its own defaults (XKB_DEFAULT_* env vars).
        IntPtr layoutPtr = MarshalOrNull(config.XkbLayout);
        IntPtr variantPtr = MarshalOrNull(config.XkbVariant);
        IntPtr optionsPtr = MarshalOrNull(config.XkbOptions);

        try
        {
            ctx = xkb_context_new(0);
            if (ctx == IntPtr.Zero)
            {
                RiverLog.Write("xkb: xkb_context_new failed");
                return false;
            }

            var names = new XkbRuleNames
            {
                rules = IntPtr.Zero,
                model = IntPtr.Zero,
                layout = layoutPtr,
                variant = variantPtr,
                options = optionsPtr,
            };

            keymap = xkb_keymap_new_from_names(ctx, ref names, 0);
            if (keymap == IntPtr.Zero)
            {
                RiverLog.Write($"xkb: failed to compile keymap (layout={config.XkbLayout ?? "<default>"}, " +
                               $"variant={config.XkbVariant ?? "<none>"}, options={config.XkbOptions ?? "<none>"})");
                return false;
            }

            keymapStr = xkb_keymap_get_as_string(keymap, XkbKeymapFormatTextV1);
            if (keymapStr == IntPtr.Zero)
            {
                RiverLog.Write("xkb: xkb_keymap_get_as_string returned null");
                return false;
            }

            byte[] bytes = Encoding.UTF8.GetBytes(Marshal.PtrToStringUTF8(keymapStr) ?? string.Empty);
            // size = content + trailing NUL (the compositor mmaps size-1).
            nuint size = (nuint)(bytes.Length + 1);

            int newFd = memfd_create("aqueous-xkb-keymap", MFD_CLOEXEC | MFD_ALLOW_SEALING);
            if (newFd < 0)
            {
                RiverLog.Write($"xkb: memfd_create failed (errno={Marshal.GetLastWin32Error()})");
                return false;
            }

            IntPtr buf = Marshal.AllocHGlobal((int)size);
            try
            {
                Marshal.Copy(bytes, 0, buf, bytes.Length);
                Marshal.WriteByte(buf, bytes.Length, 0); // trailing NUL
                nint written = write(newFd, buf, size);
                if (written != (nint)size)
                {
                    RiverLog.Write($"xkb: short write to memfd ({written}/{size}, errno={Marshal.GetLastWin32Error()})");
                    close(newFd);
                    return false;
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buf);
            }

            // Best-effort seal so the compositor can trust the contents are immutable. Ignored on
            // failure (the protocol only "recommends" sealing).
            fcntl(newFd, F_ADD_SEALS, F_SEAL_SHRINK | F_SEAL_WRITE);

            fd = newFd;
            return true;
        }
        catch (DllNotFoundException ex)
        {
            RiverLog.Write("xkb: libxkbcommon not available: " + ex.Message);
            return false;
        }
        finally
        {
            if (keymapStr != IntPtr.Zero) free(keymapStr);
            if (keymap != IntPtr.Zero) xkb_keymap_unref(keymap);
            if (ctx != IntPtr.Zero) xkb_context_unref(ctx);
            if (layoutPtr != IntPtr.Zero) Marshal.FreeCoTaskMem(layoutPtr);
            if (variantPtr != IntPtr.Zero) Marshal.FreeCoTaskMem(variantPtr);
            if (optionsPtr != IntPtr.Zero) Marshal.FreeCoTaskMem(optionsPtr);
        }
    }

    /// <summary>
    /// Closes a file descriptor previously returned by <see cref="TryCompileToFd"/>.
    /// </summary>
    public static void CloseFd(int fd)
    {
        if (fd >= 0)
        {
            close(fd);
        }
    }

    private static IntPtr MarshalOrNull(string? value)
        => string.IsNullOrEmpty(value) ? IntPtr.Zero : Marshal.StringToCoTaskMemUTF8(value);
}
