namespace Aqueous.Features.Network
{
    public enum NetworkDeviceType { Wifi, Ethernet, Unknown }
    public enum NetworkConnectionState { Disconnected, Connecting, Connected, Deactivating, Unknown }

    public record NetworkDevice(
        string Interface,
        NetworkDeviceType DeviceType,
        NetworkConnectionState State,
        string ActiveConnectionName,
        int SignalStrength // 0-100 for Wi-Fi, -1 for Ethernet
    );

    public record WifiAccessPoint(
        string Ssid,
        int Strength,
        bool IsSecured,
        string ObjectPath
    );
}
