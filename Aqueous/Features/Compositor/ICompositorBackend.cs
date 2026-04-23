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

        // --- Events ---
        /// <summary>Fires whenever the compositor reports a view add/remove/change.</summary>
        event Action? ViewsChanged;

        /// <summary>Fires whenever the active workspace changes.</summary>
        event Action? WorkspaceChanged;

        /// <summary>
        /// Starts any background listener the backend needs. Idempotent.
        /// </summary>
        void Start();
    }
}
