namespace Aqueous.Features.State;

/// <summary>
/// PR 9.12 §2.13 Step 5 — DI singleton replacing two manage-cycle
/// scoped flags previously stored as private fields on
/// <see cref="Aqueous.Features.Compositor.River.RiverWindowManagerClient"/>:
/// <list type="bullet">
///   <item><description><c>ManagerVersion</c>: the protocol version
///   advertised by the bound <c>river_window_manager_v1</c> global;
///   captured at bind time so children created on the manager are
///   bound at the parent's advertised version.</description></item>
///   <item><description><c>InsideManageSequence</c>: true between
///   the <c>manage_start</c> and <c>manage_finish</c> requests so
///   downstream layout / focus code can batch updates and avoid
///   re-entrant dispatch.</description></item>
/// </list>
///
/// <para>Pump-thread only.</para>
/// </summary>
internal sealed class ManageCycleState
{
    public uint ManagerVersion { get; set; }
    public bool InsideManageSequence { get; set; }
}
