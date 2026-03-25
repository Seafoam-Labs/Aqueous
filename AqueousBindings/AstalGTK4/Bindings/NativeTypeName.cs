using System;

[AttributeUsage(AttributeTargets.All, AllowMultiple = true)]
public sealed class NativeTypeNameAttribute : Attribute
{
    public NativeTypeNameAttribute(string name) => Name = name;
    public string Name { get; }
}
