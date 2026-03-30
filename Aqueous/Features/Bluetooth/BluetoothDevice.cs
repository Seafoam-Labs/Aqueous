namespace Aqueous.Features.Bluetooth
{
    public enum BluetoothDeviceStatus { Connected, Paired, Discovered }

    public record BluetoothDevice(
        string Address,
        string Name,
        string Icon,
        bool IsPaired,
        bool IsConnected,
        bool IsTrusted,
        short Rssi,
        BluetoothDeviceStatus Status
    );
}
