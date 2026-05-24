using System;
using System.Diagnostics;
using Aqueous.Diagnostics;

namespace Aqueous.Features.Rules;

/// <summary>
/// Tiny on-screen notification surface. Implementations forward to whichever
/// freedesktop-notification daemon (mako / dunst / fnott / …) is running inside
/// the user session. Kept narrow on purpose — Aqueous itself does not render an
/// OSD; we just emit a desktop notification and let the user's notifier style it.
/// </summary>
public interface INotificationPublisher
{
    /// <summary>
    /// Show a transient notification. Never throws; failures are logged to
    /// <see cref="RiverLog"/> and silently swallowed so notification problems
    /// can't break a <c>Super+R</c> keypress.
    /// </summary>
    /// <param name="summary">Single-line title (e.g. "Rules reloaded").</param>
    /// <param name="body">Optional multi-line body.</param>
    /// <param name="isError">If true, the notification is sent with critical urgency.</param>
    void Notify(string summary, string? body = null, bool isError = false);
}

/// <summary>
/// <see cref="INotificationPublisher"/> that shells out to <c>notify-send</c>.
/// Picked over a direct D-Bus client because Aqueous is AOT-compiled and we
/// avoid pulling in <c>Tmds.DBus</c> just for two-line notifications. If
/// <c>notify-send</c> is missing the call is logged and dropped.
/// </summary>
internal sealed class NotifySendPublisher : INotificationPublisher
{
    private const string AppName = "Aqueous";
    private const int TimeoutMs = 1500;

    public void Notify(string summary, string? body = null, bool isError = false)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "notify-send",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };
            psi.ArgumentList.Add("--app-name=" + AppName);
            psi.ArgumentList.Add("--expire-time=" + TimeoutMs.ToString(System.Globalization.CultureInfo.InvariantCulture));
            psi.ArgumentList.Add("--urgency=" + (isError ? "critical" : "normal"));
            psi.ArgumentList.Add(summary);
            if (!string.IsNullOrEmpty(body))
            {
                psi.ArgumentList.Add(body);
            }

            using var p = Process.Start(psi);
            // Fire-and-forget; notify-send exits very quickly. We don't await it so
            // a hung notifier can't block the reload path.
        }
        catch (Exception ex)
        {
            RiverLog.Write($"notify-send failed: {ex.GetType().Name}: {ex.Message}");
        }
    }
}

/// <summary>
/// No-op publisher used by unit tests and any environment without a notifier daemon.
/// </summary>
internal sealed class NullNotificationPublisher : INotificationPublisher
{
    public static readonly NullNotificationPublisher Instance = new();
    public void Notify(string summary, string? body = null, bool isError = false) { }
}
