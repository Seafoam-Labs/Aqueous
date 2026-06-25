using Xunit;

namespace Aqueous.Tests;

[CollectionDefinition(Name)]
public sealed class EnvironmentVariableTestCollection
{
    public const string Name = "Environment variable tests";
}
