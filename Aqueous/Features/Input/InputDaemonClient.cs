using System;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Diagnostics;
using Microsoft.Extensions.Logging;

namespace Aqueous.Features.Input;

/// <summary>
/// Tiny fire-and-forget client that sends an <c>apply</c> request to
/// <c>aqueous-inputd</c> over <c>$XDG_RUNTIME_DIR/aqueous-inputd.sock</c>.
/// If the daemon isn't running we log and move on — pointer accel is
/// non-essential, the WM must keep working.
/// </summary>
internal static class InputDaemonClient
{
    private static ILogger Log => Logging.Factory.CreateLogger("input");
    /// <summary>
    /// Best-effort: open the UDS, write one JSON line, close. Never
    /// throws. Total budget ≈ 1s — enough for a local socket but won't
    /// block the WM startup if the daemon hangs.
    /// </summary>
    public static void Apply(InputConfig cfg)
    {
        // Run on the thread pool so the WM ctor / reload handler isn't
        // blocked by socket I/O.
        _ = Task.Run(() => ApplyCore(cfg));
    }

    private static async Task ApplyCore(InputConfig cfg)
    {
        var path = InputDaemonProtocol.SocketPath();
        try
        {
            using var s = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(1));
            await s.ConnectAsync(new UnixDomainSocketEndPoint(path), cts.Token).ConfigureAwait(false);

            var line = InputDaemonProtocol.SerializeApply(cfg) + "\n";
            var bytes = Encoding.UTF8.GetBytes(line);
            await s.SendAsync(bytes, SocketFlags.None, cts.Token).ConfigureAwait(false);

            // Best-effort read of the ack so we surface daemon errors;
            // ignore timeouts (the daemon may close after writing).
            var buf = new byte[256];
            try
            {
                int n = await s.ReceiveAsync(buf, SocketFlags.None, cts.Token).ConfigureAwait(false);
                if (n > 0)
                {
                    Log.LogInformation("daemon: {Msg}", Encoding.UTF8.GetString(buf, 0, n).Trim());
                }
            }
            catch { /* ignore */ }
        }
        catch (SocketException)
        {
            Log.LogInformation(
                "aqueous-inputd not running at {Path}; pointer accel & per-device libinput config not applied. " +
                "Start it via `systemctl --user start aqueous-inputd` or run the binary directly.", path);
        }
        catch (OperationCanceledException)
        {
            Log.LogInformation("aqueous-inputd timed out");
        }
        catch (Exception ex)
        {
            Log.LogInformation("daemon apply failed: {Msg}", ex.Message);
        }
    }
}
