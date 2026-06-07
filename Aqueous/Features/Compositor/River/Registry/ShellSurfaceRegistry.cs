using System.Collections.Concurrent;

namespace Aqueous.Features.Compositor.River.Registry;

public class ShellSurfaceRegistry : IShellSurfaceRegistry
{
    private readonly ConcurrentDictionary<IntPtr, byte> _surfaces = new();
    public void Add(IntPtr proxy) => _surfaces[proxy] = 0;

    public void Remove(IntPtr proxy) => _surfaces.TryRemove(proxy, out _);

    public bool IsLive(IntPtr proxy) => proxy != IntPtr.Zero && _surfaces.ContainsKey(proxy);
}
