namespace Aqueous.Features.Bindings;

/// <summary>
/// Free-form custom action verb dispatcher (<c>spawn:</c>/<c>set_layout:</c>/<c>builtin:</c>)
/// extracted as a service seam over the existing class implementation.
/// </summary>
internal interface ICustomActionRunner
{
    /// <summary>
    /// Run a custom action verb. Pump-thread only.
    /// </summary>
    void Run(string verb);
}
