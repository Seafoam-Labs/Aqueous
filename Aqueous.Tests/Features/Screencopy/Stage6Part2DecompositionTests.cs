using System;
using System.Linq;
using System.Reflection;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Screencopy;
using Xunit;

namespace Aqueous.Tests.Features.Screencopy;

public class Stage6Part2DecompositionTests
{
    [Fact]
    public void RiverWindowManagerClient_NoLongerDeclares_screencopy_Field()
    {
        var t = typeof(RiverWindowManagerClient);
        var f = t.GetField("_screencopy", BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.Null(f);
    }

    [Fact]
    public void RiverWindowManagerClient_Declares_screencopyService_Field()
    {
        var t = typeof(RiverWindowManagerClient);
        var f = t.GetField("_screencopyService", BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.NotNull(f);
        Assert.Equal(typeof(IScreencopyService), f!.FieldType);
    }

    [Fact]
    public void IScreencopyService_Has_Documented_Members()
    {
        var t = typeof(IScreencopyService);
        Assert.NotNull(t.GetProperty("IsReady"));
        Assert.NotNull(t.GetMethod("CaptureOutputAsync"));
        Assert.NotNull(t.GetMethod("TryDispatchFrameEvent"));
        Assert.NotNull(t.GetMethod("TryActivate"));
    }

    [Fact]
    public void Stage6Part2_HasNoCollaboratorsBridge()
    {
        // Stage 6 Part 2 is the first bridge-less Stage. Regression guard
        // against a future PR sneaking one in.
        var bridge = typeof(IScreencopyService).Assembly.GetType(
            "Aqueous.Features.Compositor.River.Screencopy.IScreencopyServiceCollaborators");
        Assert.Null(bridge);
    }
}
