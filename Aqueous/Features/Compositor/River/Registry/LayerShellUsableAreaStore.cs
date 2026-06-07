using System;
using System.Collections.Concurrent;

namespace Aqueous.Features.Compositor.River.Registry;

/// <summary>
/// Per-output usable (non-exclusive) area reported by
/// <c>river_layer_shell_output_v1::non_exclusive_area</c>. The area is the region of the output that
/// remains after subtracting layer-surface exclusive zones (panels/bars), in <b>global</b>
/// coordinates. Recorded here when the event fires and consumed by the layout pipeline. The hint is
/// advisory — the WM may ignore it.
/// </summary>
public interface ILayerShellUsableAreaStore
{
    /// <summary>
    /// Records the usable area for the given <c>river_output_v1</c> proxy.
    /// </summary>
    void Set(IntPtr output, int x, int y, int width, int height);

    /// <summary>
    /// Retrieves the most recent usable area for the output, if any has been reported.
    /// </summary>
    bool TryGet(IntPtr output, out (int X, int Y, int Width, int Height) area);

    /// <summary>
    /// Drops any stored area for the output (e.g. on <c>river_output_v1.removed</c>).
    /// </summary>
    void Remove(IntPtr output);
}

/// <inheritdoc cref="ILayerShellUsableAreaStore"/>
public sealed class LayerShellUsableAreaStore : ILayerShellUsableAreaStore
{
    private readonly ConcurrentDictionary<IntPtr, (int X, int Y, int Width, int Height)> _areas = new();

    public void Set(IntPtr output, int x, int y, int width, int height)
    {
        if (output == IntPtr.Zero)
        {
            return;
        }

        _areas[output] = (x, y, width, height);
    }

    public bool TryGet(IntPtr output, out (int X, int Y, int Width, int Height) area)
    {
        if (output == IntPtr.Zero)
        {
            area = default;
            return false;
        }

        return _areas.TryGetValue(output, out area);
    }

    public void Remove(IntPtr output)
    {
        if (output != IntPtr.Zero)
        {
            _areas.TryRemove(output, out _);
        }
    }
}
