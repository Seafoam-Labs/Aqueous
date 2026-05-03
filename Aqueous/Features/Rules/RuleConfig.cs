namespace Aqueous.Features.Rules;

/// <summary>
/// Rule configuration for a single window.
/// </summary>
public sealed class RuleConfig
{
    public RuleMatch? Match { get; init; }
    public bool Floating { get; init; }
    public int Tag { get; init; }
    public int Width { get; init; }
    public int Height { get; init; }
    public (int,int) Position { get; init; }
}
