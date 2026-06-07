using System;
using System.Runtime.InteropServices;

namespace Aqueous.Features.Compositor.River.Connection;

/// <summary>
/// Minimal libc P/Invoke surface used by <see cref="EventPump"/> to implement a thread-safe wakeup
/// for the poll-based dispatch loop. We use an <c>eventfd</c> as the wakeup primitive: writing a
/// <c>ulong</c> makes the fd readable, which unblocks the pump's <c>poll(2)</c> immediately, and
/// reading 8 bytes drains it.
/// </summary>
internal static partial class PumpNative
{
    private const string Libc = "libc";

    // <sys/eventfd.h>
    internal const int EFD_CLOEXEC = 0x80000;   // 02000000 octal
    internal const int EFD_NONBLOCK = 0x800;    // 04000 octal

    // <poll.h>
    internal const short POLLIN = 0x0001;

    [StructLayout(LayoutKind.Sequential)]
    internal struct PollFd
    {
        public int fd;
        public short events;
        public short revents;
    }

    [LibraryImport(Libc, SetLastError = true)]
    internal static partial int eventfd(uint initval, int flags);

    [LibraryImport(Libc, SetLastError = true)]
    internal static partial int close(int fd);

    [LibraryImport(Libc, SetLastError = true)]
    internal static partial nint read(int fd, ref ulong buf, nuint count);

    [LibraryImport(Libc, SetLastError = true)]
    internal static partial nint write(int fd, ref ulong buf, nuint count);

    [LibraryImport(Libc, SetLastError = true)]
    internal static partial int poll([In, Out] PollFd[] fds, nuint nfds, int timeout);
}
