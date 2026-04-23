using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading.Tasks;

namespace Aqueous.Features.Compositor
{
    /// <summary>
    /// Compositor-agnostic contract consumed by Aqueous widgets and services.
    ///
    /// Phase 2 scaffolding: the shape of this interface mirrors the subset of
    /// <c>WayfireIpc</c> that existing callers actually use today. Future phases
    /// will migrate the widgets/services away from <c>WayfireIpc</c> directly
    /// and onto the interface so that <see cref="River.RiverBackend"/> can be
    /// swapped in without touching feature code.
    ///
    /// Return types intentionally stay close to the Wayfire JSON shapes for now
    /// to keep the Wayfire adapter a pure delegate. As the Wayfire code is
    /// deleted in later phases these will be tightened into typed records.
    /// </summary>
    /// <summary>Typed per-output state (Phase 3).</summary>
    public readonly record struct CompositorOutput(
        string Name,
        bool Focused,
        uint FocusedTags,
        uint OccupiedTags,
        uint UrgentTags,
        string? Layout);

    /// <summary>Typed focused-view state (Phase 3).</summary>
    public readonly record struct CompositorFocusedView(
        string Title,
        string? AppId,
        string? OutputName);

    public interface ICompositorBackend : IDisposable
    {
        // --- Views ---
        Task<JsonElement[]> ListViews();
        Task<JsonElement?> GetFocusedView();
        Task FocusView(int viewId);
        Task CloseView(int viewId);
        Task MinimizeView(int viewId, bool minimized);
        Task SetViewGeometry(int viewId, int x, int y, int w, int h);

        // --- Outputs / cursor ---
        Task<JsonElement[]> ListOutputs();
        Task<(int X, int Y)?> GetCursorPosition();

        // --- Workspaces ---
        Task<JsonElement> GetWorkspace();
        Task SetWorkspace(int x, int y);

        // --- Typed read accessors (Phase 3) ---
        /// <summary>Known outputs. Empty when backend has no structured output data.</summary>
        IReadOnlyList<CompositorOutput> Outputs { get; }

        /// <summary>Currently focused output, or null if unknown.</summary>
        CompositorOutput? FocusedOutput { get; }

        /// <summary>Currently focused view (title/app-id/output), or null.</summary>
        CompositorFocusedView? FocusedViewInfo { get; }

        /// <summary>Bitmask of focused (visible) tags on the focused output. 0 if unknown.</summary>
        uint FocusedTagMask { get; }

        /// <summary>Bitmask of occupied tags on the focused output. 0 if unknown.</summary>
        uint OccupiedTagMask { get; }

        /// <summary>Bitmask of urgent tags on the focused output. 0 if unknown.</summary>
        uint UrgentTagMask { get; }

        /// <summary>Lowest bit set in <see cref="FocusedTagMask"/>, or -1 if none.</summary>
        int LowestFocusedTagIndex { get; }

        // --- Events ---
        /// <summary>Fires whenever the compositor reports a view add/remove/change.</summary>
        event Action? ViewsChanged;

        /// <summary>Fires whenever the active workspace (tags on focused output) changes.</summary>
        event Action? WorkspaceChanged;

        /// <summary>Fires whenever the set of outputs or non-focused output state changes.</summary>
        event Action? OutputsChanged;

        /// <summary>
        /// Starts any background listener the backend needs. Idempotent.
        /// </summary>
        void Start();
    }
}
