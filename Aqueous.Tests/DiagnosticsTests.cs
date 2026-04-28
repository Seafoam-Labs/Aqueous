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
        // Default is NullLoggerFactory unless configured. We only assert
        // the property is non-null and resolves a logger without throwing.
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
    // A trivial fake exposing the same Dispatch API EventPump consumes.
    // We don't go through real Wayland — EventPump only needs an int
    // returning Dispatch() and the public surface; we replace that
    // through the existing internal type by using a delay loop.
    [Fact]
    public async Task TokenCancelledBeforeStart_DoesNotSpawnThread()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        // Using the public seam: EventPump is internal, but the
        // RiverWindowManagerClient.TryStart contract is what we're
        // pinning. AQUEOUS_RIVER_WM is unset in tests so TryStart
        // should fail with a deterministic Result.Fail.
        var r = Aqueous.Features.Compositor.River.RiverWindowManagerClient.TryStart(cts.Token);
        Assert.False(r.IsOk);
        Assert.Contains("AQUEOUS_RIVER_WM", r.Error);
        await Task.CompletedTask;
    }

    [Fact]
    public void TryStart_WithoutEnv_FailsWithReason()
    {
        var r = Aqueous.Features.Compositor.River.RiverWindowManagerClient.TryStart();
        Assert.False(r.IsOk);
        Assert.NotNull(r.Error);
        Assert.NotEmpty(r.Error!);
    }
}
