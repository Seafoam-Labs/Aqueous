using System.Linq;
using System.Reflection;
using Aqueous.Features.Compositor.River;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Registry;

/// <summary>
/// Stage 1 definition-of-done guard: <see cref="RiverWindowManagerClient"/>
/// must not expose any member named <c>_windows</c>, <c>_outputs</c> or
/// <c>_seats</c> — neither as a field nor as a shim property.
///
/// The previous decomposition step left these as get-only properties
/// forwarding to the corresponding registry's backing dictionary so the
/// 90+ legacy call sites in the partial-class siblings (Layout / Tags /
/// Focus / SnapZones / Dispatch event handlers / WindowStateHost) could
/// keep compiling. Stage 1 finishes the migration by rewriting every
/// such call site to use the registry directly, so the shim is no
/// longer needed. This test fails immediately if anyone re-introduces
/// it (deliberately or accidentally), forcing the new code through the
/// registry API instead.
/// </summary>
public sealed class RegistryShimAbsenceTests
{
    private static readonly string[] ForbiddenMembers = ["_windows", "_outputs", "_seats"];

    [Theory]
    [InlineData("_windows")]
    [InlineData("_outputs")]
    [InlineData("_seats")]
    public void RiverWindowManagerClient_does_not_expose_legacy_dictionary_member(string memberName)
    {
        const BindingFlags flags =
            BindingFlags.Instance |
            BindingFlags.Static |
            BindingFlags.Public |
            BindingFlags.NonPublic |
            BindingFlags.DeclaredOnly;

        var t = typeof(RiverWindowManagerClient);

        Assert.Null(t.GetField(memberName, flags));
        Assert.Null(t.GetProperty(memberName, flags));
    }

    [Fact]
    public void RiverWindowManagerClient_has_no_member_whose_name_matches_any_legacy_dictionary()
    {
        const BindingFlags flags =
            BindingFlags.Instance |
            BindingFlags.Static |
            BindingFlags.Public |
            BindingFlags.NonPublic |
            BindingFlags.DeclaredOnly;

        var t = typeof(RiverWindowManagerClient);
        var offenders = t.GetMembers(flags)
            .Where(m => ForbiddenMembers.Contains(m.Name))
            .Select(m => $"{m.MemberType} {m.Name}")
            .ToArray();

        Assert.Empty(offenders);
    }
}
