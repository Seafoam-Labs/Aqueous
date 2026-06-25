namespace Aqueous.Features.Focus;

/// <summary>
/// Tracks most-recently-focused windows per compositor workspace.
/// </summary>
internal sealed class FocusHistoryStore
{
    private readonly Dictionary<IntPtr, LinkedList<IntPtr>> _historyTracker = new();

    public void Record(IntPtr workspaceId, IntPtr window)
    {
        if (workspaceId == IntPtr.Zero || window == IntPtr.Zero)
        {
            return;
        }

        if (!_historyTracker.TryGetValue(workspaceId, out var list))
        {
            list = new LinkedList<IntPtr>();
            _historyTracker[workspaceId] = list;
        }

        var node = list.Find(window);
        if (node is not null)
        {
            list.Remove(node);
        }

        list.AddFirst(window);
    }

    public void Remove(IntPtr workspaceId, IntPtr window)
    {
        if (!_historyTracker.TryGetValue(workspaceId, out var list))
        {
            return;
        }

        var node = list.Find(window);
        if (node is not null)
        {
            list.Remove(node);
        }
    }

    public IntPtr PickWindow(IntPtr workspaceId, Func<IntPtr, bool> isValid)
    {
        if (workspaceId == IntPtr.Zero || !_historyTracker.TryGetValue(workspaceId, out var history))
        {
            return IntPtr.Zero;
        }

        for (var node = history.First; node is { };)
        {
            var next = node.Next;
            var value = node.Value;

            if (isValid(value))
            {
                return value;
            }

            history.Remove(node);
            node = next;
        }

        return IntPtr.Zero;
    }
}
