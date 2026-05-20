namespace Aqueous.Features.State;

internal sealed class ManageCycleState
{
    public uint ManagerVersion { get; set; }
    public bool InsideManageSequence { get; set; }
}
