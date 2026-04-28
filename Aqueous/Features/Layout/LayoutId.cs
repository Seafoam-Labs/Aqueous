using System;

namespace Aqueous.Features.Layout;

/// <summary>
/// Strongly-typed layout identifier. Wraps a normalized lower-case string
/// so that <see cref="LayoutRegistry"/> keys, <see cref="LayoutConfig"/>
/// slot mappings, and per-output overrides all agree on case-insensitivity
/// without each caller threading a <see cref="StringComparer"/>.
/// </summary>
/// <remarks>
/// <para>
/// Construct from untrusted input (TOML, key-binding payloads, CLI) via
/// <see cref="From(string)"/>; the <c>Tile</c>/<c>Float</c>/<c>Monocle</c>/<c>Grid</c>
/// statics expose the built-in ids that ship in the box.
/// </para>
/// <para>
/// <see cref="IsBuiltin"/> is purely informational (e.g. for diagnostics
/// or a future <c>--list-layouts</c> CLI). Resolution always goes through
/// <see cref="LayoutRegistry"/>; no code path branches on it. This is what
/// keeps custom plugin layouts on equal footing with the built-ins.
/// </para>
/// </remarks>
public readonly record struct LayoutId(string Value)
{
    /// <summary>Built-in tile (master/stack) layout.</summary>
    public static LayoutId Tile => new("tile");

    /// <summary>Built-in floating layout (no automatic tiling).</summary>
    public static LayoutId Float => new("float");

    /// <summary>Built-in monocle (one window fills the area) layout.</summary>
    public static LayoutId Monocle => new("monocle");

    /// <summary>Built-in grid layout.</summary>
    public static LayoutId Grid => new("grid");

    /// <summary>
    /// Returns <c>true</c> when <see cref="Value"/> matches one of the
    /// shipped built-in layout ids. Informational only — resolution does
    /// not branch on this property.
    /// </summary>
    public bool IsBuiltin =>
        Value is "tile" or "float" or "monocle" or "grid";

    /// <summary>
    /// Normalizes <paramref name="raw"/> by trimming surrounding whitespace
    /// and lower-casing under the invariant culture. <c>null</c> becomes
    /// the empty id. Plugin authors should pick lowercase ASCII ids (the
    /// recommended pattern is <c>^[a-z][a-z0-9._-]*$</c>) but no syntactic
    /// restriction is enforced.
    /// </summary>
    public static LayoutId From(string? raw) =>
        new((raw ?? string.Empty).Trim().ToLowerInvariant());

    /// <inheritdoc />
    public override string ToString() => Value;
}
