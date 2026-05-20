using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Compositor.River.Registry;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Stage 9 PR 9.11 — <see cref="IHostedService"/> shell that now owns
/// the Wayland connection lifecycle. <see cref="StartAsync"/> performs
/// the env-var opt-in check (via <see cref="RiverEnvironmentGuard"/>),
/// constructs the god-class client via DI, drives Connect (registry
/// roundtrip + globals + startup exec) and starts the event pump.
/// <see cref="StopAsync"/> disposes the client (which stops the pump
/// and closes the connection).
///
/// <para>
/// PR 9.11 is the penultimate Stage-9 PR. Subsequent work (PR 9.12)
/// will retire <see cref="RiverWindowManagerClient"/> entirely; the
/// host will then own the Wayland connection / GCHandle pin directly
/// and resolve each consumer service from DI without the god-class
/// indirection.
/// </para>
///
/// <para>
/// <b>Construction:</b> resolves <see cref="RiverWindowManagerClient"/>
/// from DI rather than calling its <see cref="RiverWindowManagerClient.TryStart"/>
/// static factory. The DI factory in <c>Program.cs</c> performs DI-only
/// wiring (no Connect side-effects); Connect runs here in
/// <see cref="StartAsync"/>. This separates "build the object graph"
/// from "open the Wayland connection", which makes the failure modes
/// observable and testable independently.
/// </para>
/// </summary>
internal sealed class RiverCompositorHost : IHostedService
{
    private readonly IServiceProvider _sp;
    private readonly ILogger<RiverCompositorHost>? _log;
    private RiverWindowManagerClient? _client;
    private CancellationToken _lifetimeToken;

    public RiverCompositorHost(IServiceProvider sp, ILogger<RiverCompositorHost>? log = null)
    {
        _sp = sp ?? throw new ArgumentNullException(nameof(sp));
        _log = log;
    }

    /// <summary>The resolved god-class instance once <see cref="StartAsync"/> has run, else null.</summary>
    internal RiverWindowManagerClient? Client => _client;

    public Task StartAsync(CancellationToken cancellationToken)
    {
        _log?.LogInformation("RiverCompositorHost starting...");

        // PR 9.11: env-var opt-in moved out of TryStart into the host.
        // Surfacing the friendly error here means we never trigger DI
        // construction (which used to throw InvalidOperationException
        // wrapping the same string) just to discover the user did not
        // set AQUEOUS_RIVER_WM=1.
        if (!RiverEnvironmentGuard.IsEnabled())
        {
            throw new InvalidOperationException(RiverEnvironmentGuard.NotEnabledMessage);
        }

        // PR 9.11: build the client graph from DI (no Connect side-effect),
        // then drive Connect + StartPump explicitly from here. This is the
        // structural lift the plan calls for: "Move Connect() body into
        // RiverCompositorHost.StartAsync". The Connect method itself
        // stays on the client because it touches ~20 god-class internals
        // (GCHandle pin, RegistryBinder, _manager bind site, etc.); the
        // host owns the *invocation*. A future PR will inline the body
        // here as that state migrates to dedicated services.
        _lifetimeToken = cancellationToken;
        try
        {
            _client = (RiverWindowManagerClient)_sp.GetService(typeof(RiverWindowManagerClient))!;
        }
        catch (Exception ex)
        {
            _log?.LogError(ex, "RiverWindowManagerClient construction failed");
            throw;
        }

        try
        {
            var connected = _client.Connect();
            if (!connected.IsOk)
            {
                _log?.LogError("RiverWindowManagerClient.Connect failed: {Error}", connected.Error);
                try { _client.Dispose(); } catch { /* best-effort */ }
                _client = null;
                throw new InvalidOperationException(
                    "RiverWindowManagerClient.Connect failed: " + connected.Error);
            }

            _client.StartPump(cancellationToken);
            _log?.LogInformation(
                "RiverCompositorHost started; attached as window manager (v{ManagerVersion}).",
                _client.ManagerVersion);
        }
        catch (DllNotFoundException ex)
        {
            _log?.LogError(ex, "libwayland-client could not be loaded");
            throw new InvalidOperationException(
                "libwayland-client could not be loaded: " + ex.Message, ex);
        }

        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        _log?.LogInformation("RiverCompositorHost stopping...");
        try
        {
            _client?.Dispose();
        }
        catch (Exception ex)
        {
            _log?.LogWarning(ex, "RiverWindowManagerClient.Dispose threw during shutdown");
        }
        finally
        {
            _client = null;
        }
        return Task.CompletedTask;
    }
}
