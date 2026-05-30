using Aqueous.Features.Layout;
using Xunit;

namespace Aqueous.Tests.Features.Layout;

/// <summary>
/// Phase E regression — legacy <c>[[snapzones]]</c> / <c>[[snapzones.zone]]</c> TOML keys are
/// silently ignored by <see cref="LayoutConfigLoader"/> for one release after the SnapZones
/// subsystem was removed. Old user configs must continue to parse without error, and surrounding
/// sections must not be corrupted by the ignored blocks.
/// </summary>
public class LegacySnapZonesIgnoredTests
{
    [Fact]
    public void LegacySnapZonesBlock_IsIgnored_AndDoesNotThrow()
    {
        var toml = """
            [[snapzones]]
            output = "*"
            layout = "Priority Grid"
            activator = "Shift"

            [[snapzones.zone]]
            name = "Top Left"
            x = 0.0
            y = 0.0
            w = 0.25
            h = 0.5

            [[snapzones.zone]]
            name = "Center"
            x = 0.25
            y = 0.0
            w = 0.5
            h = 1.0
            """;

        var cfg = LayoutConfigLoader.Parse(toml);

        Assert.NotNull(cfg);
    }

    [Fact]
    public void LegacySnapZonesBlock_DoesNotLeakIntoFollowingSection()
    {
        // Regression guard: a stale [[snapzones]] / [[snapzones.zone]] block followed by a real
        // section must flush cleanly so the next section's keys are honoured.
        var toml = """
            [[snapzones]]
            output = "*"
            layout = "Priority Grid"

            [[snapzones.zone]]
            name = "Top Left"
            x = 0.0
            y = 0.0
            w = 0.25
            h = 0.5

            [layout]
            default = "scrolling"

            [[exec]]
            name    = "bar"
            command = "qs -c noctalia-shell"
            """;

        var cfg = LayoutConfigLoader.Parse(toml);

        Assert.Equal("scrolling", cfg.DefaultLayout);
        var entry = Assert.Single(cfg.Exec.Entries);
        Assert.Equal("bar", entry.Name);
    }
}
