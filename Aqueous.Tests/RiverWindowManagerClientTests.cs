using System;
using System.Collections.Generic;
using System.Threading;
using Aqueous.Features.Compositor.River;
using Xunit;

namespace Aqueous.Tests;

/// <summary>
/// Coverage tests for <see cref="RiverWindowManagerClient"/>. The class
/// is <c>internal sealed unsafe partial</c>; <c>InternalsVisibleTo</c>
/// already exposes it to <c>Aqueous.Tests</c>. We can't bring up a real
/// River compositor in CI, so we exercise the deterministic, no-display
/// surfaces:
///
///   * <see cref="RiverWindowManagerClient.TryStart"/> env-var gating
///     (the unset path is also pinned in <c>EventPumpCancellationTests</c>;
///     here we additionally cover the env-set / no-Wayland-display path,
///     which must Fail rather than throw).
///   * The static <see cref="RiverWindowManagerClient.Log"/> delegate
///     swap (call sites pre-date structured logging; this is the only
///     observation seam tests have).
///
/// All tests in this class manipulate process-global env vars and the
/// static <c>Log</c> delegate, so they are forced into a single
/// xUnit collection that runs them sequentially.
/// </summary>
[Collection(nameof(RiverWindowManagerClientTests))]
[CollectionDefinition(nameof(RiverWindowManagerClientTests), DisableParallelization = true)]
public class RiverWindowManagerClientTests
{
    /// <summary>
    /// Snapshot/restore the env vars and <c>Log</c> sink that every test
    /// in this file mutates, so failures can't leak across tests or pollute
    /// other test classes.
    /// </summary>
    private sealed class EnvScope : IDisposable
    {
        private readonly string? _aqueous;
        private readonly string? _waylandDisplay;
        private readonly string? _waylandSocket;
        private readonly Action<string> _log;

        public EnvScope()
        {
            _aqueous = Environment.GetEnvironmentVariable("AQUEOUS_RIVER_WM");
            _waylandDisplay = Environment.GetEnvironmentVariable("WAYLAND_DISPLAY");
            _waylandSocket = Environment.GetEnvironmentVariable("WAYLAND_SOCKET");
            _log = RiverWindowManagerClient.Log;
        }

        public void Dispose()
        {
            Environment.SetEnvironmentVariable("AQUEOUS_RIVER_WM", _aqueous);
            Environment.SetEnvironmentVariable("WAYLAND_DISPLAY", _waylandDisplay);
            Environment.SetEnvironmentVariable("WAYLAND_SOCKET", _waylandSocket);
            RiverWindowManagerClient.Log = _log;
        }
    }

    // covers TryStart fail-fast: AQUEOUS_RIVER_WM unset
    [Fact]
    public void TryStart_FailsWhenEnvUnset()
    {
        using var _ = new EnvScope();
        Environment.SetEnvironmentVariable("AQUEOUS_RIVER_WM", null);
        var r = RiverWindowManagerClient.TryStart();
        Assert.False(r.IsOk);
        Assert.Contains("AQUEOUS_RIVER_WM", r.Error);
    }

    // covers TryStart fail-fast: AQUEOUS_RIVER_WM set to a non-"1" value
    [Theory]
    [InlineData("0")]
    [InlineData("true")]
    [InlineData("")]
    public void TryStart_FailsWhenEnvNotExactlyOne(string value)
    {
        using var _ = new EnvScope();
        Environment.SetEnvironmentVariable("AQUEOUS_RIVER_WM", value);
        var r = RiverWindowManagerClient.TryStart();
        Assert.False(r.IsOk);
        Assert.Contains("AQUEOUS_RIVER_WM", r.Error);
    }

    // covers TryStart honours the cancellation-token parameter signature
    // (token is plumbed to the pump; with env unset the call must still
    // fail synchronously without observing the token).
    [Fact]
    public void TryStart_WithCancelledToken_StillEnvGated()
    {
        using var _ = new EnvScope();
        Environment.SetEnvironmentVariable("AQUEOUS_RIVER_WM", null);
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        var r = RiverWindowManagerClient.TryStart(cts.Token);
        Assert.False(r.IsOk);
    }

    // covers the env-set / no-display branch: Connect() must report a
    // Wayland connect failure and TryStart must surface it as Fail without
    // throwing. We deliberately point WAYLAND_DISPLAY at a non-existent
    // socket so this is deterministic regardless of whether the test
    // host has a live compositor.
    [Fact]
    public void TryStart_EnvSet_NoDisplay_FailsGracefully()
    {
        using var _ = new EnvScope();
        Environment.SetEnvironmentVariable("AQUEOUS_RIVER_WM", "1");
        Environment.SetEnvironmentVariable("WAYLAND_DISPLAY",
            "aqueous-tests-nonexistent-" + Guid.NewGuid().ToString("N"));
        Environment.SetEnvironmentVariable("WAYLAND_SOCKET", null);

        var r = RiverWindowManagerClient.TryStart();
        Assert.False(r.IsOk);
        Assert.False(string.IsNullOrEmpty(r.Error));
    }

    // covers Log delegate swap: a custom sink replaces the default and
    // receives every message routed through the static Log property; the
    // EnvScope restores the prior sink on dispose so other tests are
    // unaffected.
    [Fact]
    public void Log_DelegateIsSwappable_AndReceivesMessages()
    {
        using var _ = new EnvScope();
        var captured = new List<string>();
        RiverWindowManagerClient.Log = msg => captured.Add(msg);

        RiverWindowManagerClient.Log("hello from test");
        RiverWindowManagerClient.Log("ERROR boom");

        Assert.Equal(new[] { "hello from test", "ERROR boom" }, captured);
    }

    // covers EnvScope restoring the Log sink: after the scope disposes,
    // the previously-installed delegate is back in place.
    [Fact]
    public void Log_EnvScope_RestoresPreviousSink()
    {
        var original = RiverWindowManagerClient.Log;
        using (var _ = new EnvScope())
        {
            RiverWindowManagerClient.Log = _ignored => { };
            Assert.NotSame(original, RiverWindowManagerClient.Log);
        }
        Assert.Same(original, RiverWindowManagerClient.Log);
    }

    // covers that the Log property is never null (default sink is installed
    // even after a custom sink is uninstalled via EnvScope).
    [Fact]
    public void Log_DefaultSink_IsNeverNull()
    {
        Assert.NotNull(RiverWindowManagerClient.Log);
        // Smoke: calling the default sink must not throw on any classification branch.
        RiverWindowManagerClient.Log("ERROR something failed");
        RiverWindowManagerClient.Log("warn something unavailable");
        RiverWindowManagerClient.Log("connected to compositor");
        RiverWindowManagerClient.Log("manage_start received");
        RiverWindowManagerClient.Log("session_locked");
        RiverWindowManagerClient.Log("session_unlocked");
        RiverWindowManagerClient.Log("plain debug message");
        RiverWindowManagerClient.Log(string.Empty);
    }
}
