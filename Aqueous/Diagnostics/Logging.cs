using System;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Aqueous.Diagnostics;

/// <summary>
/// Process-wide <see cref="ILoggerFactory"/> ambient. Exists because the
/// River feature is composed of many <c>partial class</c> files that share
/// a single instance of <see cref="Compositor.River.RiverWindowManagerClient"/>;
/// threading a factory through a constructor would touch every partial.
///
/// <para>
/// Configure once from <c>Program.cs</c> via
/// <see cref="ConfigureFromEnvironment"/> (honours the <c>AQUEOUS_LOG</c>
/// environment variable). Until configured, <see cref="Factory"/> is a
/// <see cref="NullLoggerFactory"/> so that unit tests pulling in this
/// namespace don't emit unwanted output.
/// </para>
/// </summary>
public static class Logging
{
    /// <summary>
    /// The ambient factory. Replace via <see cref="SetFactory"/> at startup;
    /// otherwise resolves to <see cref="NullLoggerFactory.Instance"/>.
    /// </summary>
    public static ILoggerFactory Factory { get; private set; } = NullLoggerFactory.Instance;

    /// <summary>Replace the ambient factory; idempotent.</summary>
    public static void SetFactory(ILoggerFactory factory)
    {
        ArgumentNullException.ThrowIfNull(factory);
        Factory = factory;
    }

    /// <summary>
    /// Reads <c>AQUEOUS_LOG</c> (one of <c>trace|debug|info|warn|error</c>,
    /// default <c>info</c>) and installs a console-backed factory at that
    /// minimum level. Safe to call multiple times — last call wins.
    /// </summary>
    public static void ConfigureFromEnvironment()
    {
        var level = ParseLevel(Environment.GetEnvironmentVariable("AQUEOUS_LOG"));
        var factory = LoggerFactory.Create(builder =>
        {
            builder.SetMinimumLevel(level);
            builder.AddSimpleConsole(o =>
            {
                o.SingleLine = true;
                o.TimestampFormat = "HH:mm:ss.fff ";
            });
        });
        SetFactory(factory);
    }

    /// <summary>Convenience wrapper for <c>Logging.Factory.CreateLogger&lt;T&gt;()</c>.</summary>
    public static ILogger<T> For<T>() => Factory.CreateLogger<T>();

    private static LogLevel ParseLevel(string? raw) => raw?.Trim().ToLowerInvariant() switch
    {
        "trace" => LogLevel.Trace,
        "debug" => LogLevel.Debug,
        "info" or "information" or null or "" => LogLevel.Information,
        "warn" or "warning" => LogLevel.Warning,
        "error" => LogLevel.Error,
        "none" or "off" => LogLevel.None,
        _ => LogLevel.Information,
    };
}
