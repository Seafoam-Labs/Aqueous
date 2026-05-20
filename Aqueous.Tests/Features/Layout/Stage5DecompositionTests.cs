using System;
using System.Linq;
using System.Reflection;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Layout;
using Aqueous.Features.Layout;
using Xunit;

namespace Aqueous.Tests.Features.Layout;

/// <summary>
/// Reflection-based regression guards for the Stage 5 decomposition.
/// These pin the structural changes — they fail loudly if a future
/// commit re-introduces the old layout that the stage was designed
/// to eliminate.
/// </summary>
public sealed class Stage5DecompositionTests
{
    [Fact]
    public void GodClass_NoLongerDeclares_InsideManageSequenceField()
    {
        // Stage 5 moved the manage-cycle flush flag onto
        // IManagerRequestSender. A property of the same name still
        // exists on RiverWindowManagerClient (write-through to the
        // service) but the *field* must be gone — its presence would
        // create two storage slots that drift out of sync.
        var field = typeof(RiverWindowManagerClient).GetField(
            "_insideManageSequence",
            BindingFlags.NonPublic | BindingFlags.Instance);
        // The auto-property backing field has a different name; assert
        // there's no field declared with this literal name.
        Assert.True(
            field is null ||
            field.Name.StartsWith("<", StringComparison.Ordinal),
            "RiverWindowManagerClient must not declare a private field "
            + "named '_insideManageSequence'; the manage-cycle flag now "
            + "lives on IManagerRequestSender.");
    }

    [Fact]
    public void GodClass_HoldsManagerRequestSender_Field()
    {
        var field = typeof(RiverWindowManagerClient).GetField(
            "_managerRequestSender",
            BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.NotNull(field);
        Assert.Equal(typeof(IManagerRequestSender), field!.FieldType);
    }

    [Fact]
    public void GodClass_HoldsLayoutProposer_Field()
    {
        var field = typeof(RiverWindowManagerClient).GetField(
            "_layoutProposer",
            BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.NotNull(field);
        Assert.Equal(typeof(ILayoutProposer), field!.FieldType);
    }

    [Fact]
    public void GodClass_ImplementsLayoutProposerCollaborators()
    {
        // The Stage 5 facade delegates back through this bridge. The
        // god class must still expose it (only retired in Stage 5b).
        Assert.Contains(
            typeof(ILayoutProposerCollaborators),
            typeof(RiverWindowManagerClient).GetInterfaces());
    }

    [Fact]
    public void GodClass_NoLongerImplements_ITagServiceCollaborators()
    {
        // Belt-and-braces companion to the type-deleted guard in
        // TagServiceTests: even reflecting over the god class's
        // interface list must not surface the retired bridge.
        var ifaces = typeof(RiverWindowManagerClient).GetInterfaces();
        Assert.DoesNotContain(
            ifaces,
            t => t.FullName ==
                 "Aqueous.Features.Compositor.River.Tags.ITagServiceCollaborators");
    }

    [Fact]
    public void FocusServiceCollaborators_Fully_Retired_AsOfPr96()
    {
        // Stage 9 PR 9.6: IFocusServiceCollaborators bridge fully deleted.
        // (Stage 5 only shrunk it; PR 9.6 removes it entirely.)
        var t = typeof(RiverWindowManagerClient).Assembly.GetType(
            "Aqueous.Features.Compositor.River.Focus.IFocusServiceCollaborators");
        Assert.Null(t);
    }

    [Fact]
    public void ManagerRequestSender_PartialFile_Deleted()
    {
        // The original 61-line ManagerRequestSender partial file is
        // gone. Its three private methods (SendManagerRequest /
        // ScheduleManage / MarshalUtf8) live on
        // ManagerRequestSender.cs (the new service) and the bridge
        // partial (RiverWindowManagerClient.ManagerRequestSenderBridge).
        var brokenType = typeof(RiverWindowManagerClient).Assembly.GetType(
            "Aqueous.Features.Compositor.River.RiverWindowManagerClient+ManagerRequestSender",
            throwOnError: false);
        Assert.Null(brokenType);
    }
}
