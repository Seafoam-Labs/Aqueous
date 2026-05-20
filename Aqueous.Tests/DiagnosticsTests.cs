using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Diagnostics;
using Microsoft.Extensions.Logging;
using Xunit;

namespace Aqueous.Tests;

public class ResultTests
{
    [Fact]
    public void Ok_HasNoError()
    {
        Assert.True(Result.Ok.IsOk);
        Assert.Null(Result.Ok.Error);
    }

    [Fact]
    public void Fail_CarriesError()
    {
        var r = Result.Fail("boom");
        Assert.False(r.IsOk);
        Assert.Equal("boom", r.Error);
    }

    [Fact]
    public void Fail_RejectsNullOrEmptyMessage()
    {
        Assert.Throws<ArgumentException>(() => Result.Fail(string.Empty));
        Assert.Throws<ArgumentNullException>(() => Result.Fail(null!));
    }

    [Fact]
    public void GenericResult_OkCarriesValue()
    {
        var r = Result<int>.Ok(42);
        Assert.True(r.IsOk);
        Assert.Equal(42, r.Value);
        Assert.Null(r.Error);
    }

    [Fact]
    public void GenericResult_FailCarriesError()
    {
        var r = Result<int>.Fail("nope");
        Assert.False(r.IsOk);
        Assert.Equal(0, r.Value);
        Assert.Equal("nope", r.Error);
    }

    [Fact]
    public void GenericResult_RecordEqualitySemantics()
    {
        Assert.Equal(Result<string>.Ok("x"), Result<string>.Ok("x"));
        Assert.NotEqual(Result<string>.Ok("x"), Result<string>.Ok("y"));
    }
}

public class LoggingTests
{
    [Fact]
    public void Factory_DefaultsToNull()
    {
        // Default is NullLoggerFactory unless configured. We only assert the property is non-null and
        // resolves a logger without throwing.
        var logger = Logging.For<LoggingTests>();
        Assert.NotNull(logger);
        // Should swallow without throwing on any level.
        logger.LogInformation("smoke");
    }

    [Fact]
    public void SetFactory_RejectsNull()
    {
        Assert.Throws<ArgumentNullException>(() => Logging.SetFactory(null!));
    }
}

public class EventPumpCancellationTests
{
    // A trivial fake exposing the same Dispatch API EventPump consumes. We don't go through real
    // Wayland — EventPump only needs an int returning Dispatch and the public surface; we replace
    // that through the existing internal type by using a delay loop. the static TryStart factory was
    // retired; lifecycle gating now lives in RiverEnvironmentGuard, driven by
    // RiverCompositorHost.StartAsync. These two tests pin the env-var contract directly against the
    // guard.
    [Fact]
    public async Task EnvironmentGuard_ReportsDisabled_WhenEnvUnset()
    {
        var prior = Environment.GetEnvironmentVariable("AQUEOUS_RIVER_WM");
        try
        {
            Environment.SetEnvironmentVariable("AQUEOUS_RIVER_WM", null);
            Assert.False(Aqueous.Features.Compositor.River.RiverEnvironmentGuard.IsEnabled());
            Assert.Contains(
                "AQUEOUS_RIVER_WM",
                Aqueous.Features.Compositor.River.RiverEnvironmentGuard.NotEnabledMessage);
        }
        finally
        {
            Environment.SetEnvironmentVariable("AQUEOUS_RIVER_WM", prior);
        }
        await Task.CompletedTask;
    }

    [Fact]
    public void EnvironmentGuard_NotEnabledMessage_IsNonEmpty()
    {
        var msg = Aqueous.Features.Compositor.River.RiverEnvironmentGuard.NotEnabledMessage;
        Assert.NotNull(msg);
        Assert.NotEmpty(msg);
    }
}
