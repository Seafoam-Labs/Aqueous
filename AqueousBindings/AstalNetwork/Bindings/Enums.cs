namespace Aqueous.Bindings.AstalNetwork
{
    public enum AstalNetworkPrimary
    {
        Unknown,
        Wired,
        Wifi
    }

    public enum AstalNetworkConnectivity
    {
        Unknown,
        None,
        Portal,
        Limited,
        Full
    }

    public enum AstalNetworkState
    {
        Unknown = 0,
        Asleep = 10,
        Disconnected = 20,
        Disconnecting = 30,
        Connecting = 40,
        ConnectedLocal = 50,
        ConnectedSite = 60,
        ConnectedGlobal = 70
    }

    public enum AstalNetworkDeviceState
    {
        Unknown = 0,
        Unmanaged = 10,
        Unavailable = 20,
        Disconnected = 30,
        Prepare = 40,
        Config = 50,
        NeedAuth = 60,
        IpConfig = 70,
        IpCheck = 80,
        Secondaries = 90,
        Activated = 100,
        Deactivating = 110,
        Failed = 120
    }

    public enum AstalNetworkInternet
    {
        Connected,
        Connecting,
        Disconnected
    }
}
