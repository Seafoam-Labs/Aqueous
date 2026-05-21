using System;

namespace Aqueous.Features.Layout;

/// <summary>
/// Identity selector for a physical output, parsed from <c>wm.toml</c> blocks such as
/// <c>[[output]]</c> and <c>[[snapzones]]</c>. Mirrors the <c>edid</c>/<c>name</c> rule used by
/// <c>Aqueous.OutputDaemon.Validator.Resolve</c>: <c>Edid</c> wins, then <c>Make</c>/<c>Model</c>/
/// <c>Serial</c> (all-of, case-insensitive, non-empty fields only), then <c>Name</c> as the
/// connector-string fallback. At least one of the five fields must be non-empty — a fully empty
/// selector matches nothing.
/// </summary>
/// <param name="Name">Connector name (e.g. <c>DP-1</c>). Exact, case-sensitive match.</param>
/// <param name="Edid">SHA-256 EDID hash, format <c>sha256:&lt;hex&gt;</c>. Case-insensitive.</param>
/// <param name="Make">EDID manufacturer string. Case-insensitive equality.</param>
/// <param name="Model">EDID model string. Case-insensitive equality.</param>
/// <param name="Serial">EDID serial string. Case-insensitive equality.</param>
public sealed record OutputSelector(
    string? Name = null,
    string? Edid = null,
    string? Make = null,
    string? Model = null,
    string? Serial = null)
{
    /// <summary>
    /// True if this selector has no usable fields and therefore cannot match any output.
    /// </summary>
    public bool IsEmpty =>
        string.IsNullOrEmpty(Name)
        && string.IsNullOrEmpty(Edid)
        && string.IsNullOrEmpty(Make)
        && string.IsNullOrEmpty(Model)
        && string.IsNullOrEmpty(Serial);

    /// <summary>
    /// True if this selector matches a live output described by the supplied identity tuple.
    /// Resolution order matches the daemon: EDID wins, then make/model/serial (all non-empty fields
    /// must equal), then name.
    /// </summary>
    public bool Matches(string? name, string? edid, string? make, string? model, string? serial)
    {
        if (!string.IsNullOrEmpty(Edid))
        {
            return string.Equals(Edid, edid, StringComparison.OrdinalIgnoreCase);
        }

        bool hasMms = !string.IsNullOrEmpty(Make)
                      || !string.IsNullOrEmpty(Model)
                      || !string.IsNullOrEmpty(Serial);
        if (hasMms)
        {
            if (!string.IsNullOrEmpty(Make)
                && !string.Equals(Make, make, StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }
            if (!string.IsNullOrEmpty(Model)
                && !string.Equals(Model, model, StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }
            if (!string.IsNullOrEmpty(Serial)
                && !string.Equals(Serial, serial, StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }
            return true;
        }

        if (!string.IsNullOrEmpty(Name))
        {
            return string.Equals(Name, name, StringComparison.Ordinal);
        }

        return false;
    }
}
