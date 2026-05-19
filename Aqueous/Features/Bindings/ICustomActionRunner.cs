namespace Aqueous.Features.Bindings;

/// <summary>
/// Stage 7: free-form custom action verb dispatcher
/// (<c>spawn:</c>/<c>set_layout:</c>/<c>builtin:</c>) extracted as a
/// service seam over the existing god-class implementation.
/// </summary>
internal interface ICustomActionRunner
{
    /// <summary>Run a custom action verb. Pump-thread only.</summary>
    void Run(string verb);
}
