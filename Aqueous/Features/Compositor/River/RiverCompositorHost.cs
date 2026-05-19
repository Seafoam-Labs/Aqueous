using System;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Stage 9 PR 9.2 — thin <see cref="IHostedService"/> shell around
/// <see cref="RiverWindowManagerClient"/>.
///
/// <para>
/// This PR does not move state yet; it only introduces the host wrapper.
/// <see cref="StartAsync"/> resolves the god class from DI (which triggers
/// the singleton factory in <c>Program.cs</c> — that's where
/// <see cref="RiverWindowManagerClient.TryStart"/> runs and performs
/// Connect + roundtrip + StartPump). <see cref="StopAsync"/> disposes it.
/// </para>
///
/// <para>
/// PRs 9.3–9.11 progressively migrate the Connect/Dispose bodies onto this
/// host as bridges are retired and god-class state moves to dedicated
/// services. PR 9.12 deletes <see cref="RiverWindowManagerClient"/>
/// entirely; the host then owns the Wayland connection lifecycle directly.
/// </para>
/// </summary>
internal sealed class RiverCompositorHost : IHostedService
{
    private readonly IServiceProvider _sp;
    private readonly ILogger<RiverCompositorHost>? _log;
    private RiverWindowManagerClient? _client;

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
        // Resolving the singleton triggers RiverWindowManagerClient.TryStart
        // via its DI factory (Connect + roundtrip + StartPump runs there).
        _client = (RiverWindowManagerClient)_sp.GetService(typeof(RiverWindowManagerClient))!;
        _log?.LogInformation("RiverCompositorHost started.");
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
