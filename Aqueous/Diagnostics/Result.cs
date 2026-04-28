using System;

namespace Aqueous.Diagnostics;

/// <summary>
/// Outcome value for operations that can fail in a way the caller is
/// expected to surface — typically environment / configuration problems
/// (no Wayland display, missing manager global, etc.). Failures that
/// represent programmer error or "should never happen" conditions
/// continue to throw exceptions; <see cref="Result"/> is reserved for
/// situations where the failure reason is information the caller wants
/// to display.
/// </summary>
/// <param name="IsOk">True when the operation succeeded.</param>
/// <param name="Error">
/// Human-readable failure description; <see langword="null"/> when
/// <paramref name="IsOk"/> is true.
/// </param>
public readonly record struct Result(bool IsOk, string? Error)
{
    /// <summary>Convenience success value.</summary>
    public static Result Ok { get; } = new(true, null);

    /// <summary>Construct a failure with the given human-readable message.</summary>
    public static Result Fail(string error)
    {
        ArgumentException.ThrowIfNullOrEmpty(error);
        return new Result(false, error);
    }
}

/// <summary>
/// Outcome value for operations that produce a value on success and a
/// human-readable error string on failure. See <see cref="Result"/> for
/// the rationale.
/// </summary>
public readonly record struct Result<T>(bool IsOk, T? Value, string? Error)
{
    /// <summary>Construct a success carrying the given value.</summary>
    public static Result<T> Ok(T value) => new(true, value, null);

    /// <summary>Construct a failure with the given human-readable message.</summary>
    public static Result<T> Fail(string error)
    {
        ArgumentException.ThrowIfNullOrEmpty(error);
        return new Result<T>(false, default, error);
    }
}
