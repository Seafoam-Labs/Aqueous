namespace Aqueous.Bindings.AstalBattery
{
    public enum AstalBatteryType
    {
        Unknown,
        LinePower,
        Battery,
        Ups,
        Monitor,
        Mouse,
        Keyboard,
        Pda,
        Phone,
        MediaPlayer,
        Tablet,
        Computer,
        GamingInput,
        Pen,
        Touchpad,
        Modem,
        Network,
        Headset,
        Speakers,
        Headphones,
        Video,
        OtherAudio,
        RemoveControl,
        Printer,
        Scanner,
        Camera,
        Wearable,
        Toy,
        BluetoothGeneric
    }

    public enum AstalBatteryState
    {
        Unknown,
        Charging,
        Discharging,
        Empty,
        FullyCharged,
        PendingCharge,
        PendingDischarge
    }

    public enum AstalBatteryTechnology
    {
        Unknown,
        LithiumIon,
        LithiumPolymer,
        LithiumIronPhosphate,
        LeadAcid,
        NickelCadmium,
        NickelMetalHydride
    }

    public enum AstalBatteryWarningLevel
    {
        Unknown,
        None,
        Discharging,
        Low,
        Critical,
        Action
    }

    public enum AstalBatteryBatteryLevel
    {
        Unknown,
        None,
        Low,
        Critical,
        Normal,
        High,
        Full
    }
}
