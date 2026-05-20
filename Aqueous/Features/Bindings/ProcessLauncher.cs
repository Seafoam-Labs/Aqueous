using System;
using System.Collections.Generic;
using System.Diagnostics;

namespace Aqueous.Features.Bindings;

/// <summary>
/// AOT-safe implementation of <see cref="IProcessLauncher"/>. Pins <c>UseShellExecute = false</c>;
/// never propagates exceptions.
/// </summary>
internal sealed class ProcessLauncher : IProcessLauncher
{
    public bool Start(
        string fileName,
        IReadOnlyList<string>? arguments = null,
        IReadOnlyDictionary<string, string?>? environment = null)
    {
        if (string.IsNullOrEmpty(fileName))
        {
            return false;
        }

        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = fileName,
                UseShellExecute = false,
                CreateNoWindow = true,
            };

            if (arguments is not null)
            {
                foreach (var arg in arguments)
                {
                    psi.ArgumentList.Add(arg);
                }
            }

            if (environment is not null)
            {
                foreach (var kv in environment)
                {
                    if (kv.Value is null)
                    {
                        psi.EnvironmentVariables.Remove(kv.Key);
                    }
                    else
                    {
                        psi.EnvironmentVariables[kv.Key] = kv.Value;
                    }
                }
            }

            return Process.Start(psi) is not null;
        }
        catch (Exception)
        {
            return false;
        }
    }
}
