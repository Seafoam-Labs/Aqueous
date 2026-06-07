namespace Aqueous.Features.Compositor.River.Registry;

public interface IShellSurfaceRegistry
{
    int Count { get; }
    void Add(IntPtr proxy);
    void Remove(IntPtr proxy);
    bool IsLive(IntPtr proxy);
}
