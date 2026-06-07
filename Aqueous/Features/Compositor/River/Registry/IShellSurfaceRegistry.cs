namespace Aqueous.Features.Compositor.River.Registry;

public interface IShellSurfaceRegistry
{
    void Add(IntPtr proxy);
    void Remove(IntPtr proxy);
    bool IsLive(IntPtr proxy);
}
