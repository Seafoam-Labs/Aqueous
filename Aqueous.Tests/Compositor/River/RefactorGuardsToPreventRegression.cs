using System;
using System.Linq;
using System.Reflection;
using Aqueous.Features.Bindings;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Aqueous.Features.Focus;
using Aqueous.Features.Layout;
using Aqueous.Features.Screencopy;
using Aqueous.Features.SnapZones;
using Aqueous.Features.Tags;
using Xunit;

namespace Aqueous.Tests.Compositor.River;

/// <summary>
/// Stage 9 PR 9.1 regression guards: every service the god class
/// constructs inline must be exposed via an <c>internal</c> accessor
/// property so Program.cs can register it in DI via factory lambda.
/// These tests pin the accessor shape so future refactors (PR 9.2–9.12)
/// can't silently drop a registration. They do NOT instantiate
/// <see cref="RiverWindowManagerClient"/> (its ctor is private and
/// runs Wayland P/Invokes); they reflect on the type only.
/// </summary>
public sealed class RefactorGuardsToPreventRegression
{
    private static readonly Type ClientType = typeof(RiverWindowManagerClient);
    private const BindingFlags AccessorFlags =
        BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;

    [Theory]
    [InlineData("EventDispatcher", typeof(IEventDispatcher))]
    [InlineData("FocusService", typeof(IFocusService))]
    [InlineData("TagService", typeof(ITagService))]
    [InlineData("ManagerRequestSender", typeof(IManagerRequestSender))]
    [InlineData("LayoutProposer", typeof(ILayoutProposer))]
    [InlineData("SnapZoneService", typeof(ISnapZoneService))]
    [InlineData("ScreencopyService", typeof(IScreencopyService))]
    [InlineData("ProcessLauncher", typeof(IProcessLauncher))]
    [InlineData("CustomActionRunner", typeof(ICustomActionRunner))]
    [InlineData("KeyBindingRegistrar", typeof(IKeyBindingRegistrar))]
    [InlineData("KeyBindingRouter", typeof(IKeyBindingRouter))]
    public void Service_accessor_property_exists_with_expected_interface_type(
        string propertyName,
        Type expectedType)
    {
        var prop = ClientType.GetProperty(propertyName, AccessorFlags);
        Assert.NotNull(prop);
        Assert.Equal(expectedType, prop!.PropertyType);
        Assert.True(prop.CanRead, $"{propertyName} must have a getter");
    }

    [Theory]
    [InlineData("LayerShellHandler", typeof(LayerShellEventHandler))]
    [InlineData("OutputHandler", typeof(OutputEventHandler))]
    [InlineData("SeatHandler", typeof(SeatEventHandler))]
    [InlineData("WindowHandler", typeof(WindowEventHandler))]
    [InlineData("ManagerHandler", typeof(ManagerEventHandler))]
    [InlineData("SuperKeyBindingHandler", typeof(SuperKeyBindingEventHandler))]
    [InlineData("DragPointerBindingHandler", typeof(DragPointerBindingEventHandler))]
    [InlineData("RegistryHandler", typeof(RegistryEventHandler))]
    [InlineData("KeyBindingHandler", typeof(KeyBindingEventHandler))]
    [InlineData("ScreencopyFrameHandler", typeof(ScreencopyFrameHandler))]
    public void Handler_accessor_property_exists_with_expected_concrete_type(
        string propertyName,
        Type expectedType)
    {
        var prop = ClientType.GetProperty(propertyName, AccessorFlags);
        Assert.NotNull(prop);
        Assert.Equal(expectedType, prop!.PropertyType);
        Assert.True(prop.CanRead, $"{propertyName} must have a getter");
    }

    [Theory]
    [InlineData("_layerShellHandler", typeof(LayerShellEventHandler))]
    [InlineData("_outputHandler", typeof(OutputEventHandler))]
    [InlineData("_seatHandler", typeof(SeatEventHandler))]
    [InlineData("_windowHandler", typeof(WindowEventHandler))]
    [InlineData("_managerHandler", typeof(ManagerEventHandler))]
    [InlineData("_superKeyBindingHandler", typeof(SuperKeyBindingEventHandler))]
    [InlineData("_dragPointerBindingHandler", typeof(DragPointerBindingEventHandler))]
    [InlineData("_registryHandler", typeof(RegistryEventHandler))]
    [InlineData("_keyBindingHandler", typeof(KeyBindingEventHandler))]
    [InlineData("_screencopyFrameHandler", typeof(ScreencopyFrameHandler))]
    public void Handler_backing_field_exists_with_expected_type(string fieldName, Type expectedType)
    {
        var field = ClientType.GetField(fieldName, BindingFlags.Instance | BindingFlags.NonPublic);
        Assert.NotNull(field);
        Assert.Equal(expectedType, field!.FieldType);
        Assert.True(field.IsInitOnly, $"{fieldName} must be readonly");
    }

    [Fact]
    public void All_eleven_service_accessors_are_distinct_property_names()
    {
        // Sanity check: the InlineData lists above don't accidentally
        // share a name with a handler accessor.
        var serviceNames = new[]
        {
            "EventDispatcher", "FocusService", "TagService",
            "ManagerRequestSender", "LayoutProposer", "SnapZoneService",
            "ScreencopyService", "ProcessLauncher", "CustomActionRunner",
            "KeyBindingRegistrar", "KeyBindingRouter",
        };
        var handlerNames = new[]
        {
            "LayerShellHandler", "OutputHandler", "SeatHandler",
            "WindowHandler", "ManagerHandler", "SuperKeyBindingHandler",
            "DragPointerBindingHandler", "RegistryHandler",
            "KeyBindingHandler", "ScreencopyFrameHandler",
        };
        Assert.Empty(serviceNames.Intersect(handlerNames));
        Assert.Equal(11, serviceNames.Distinct().Count());
        Assert.Equal(10, handlerNames.Distinct().Count());
    }
}
