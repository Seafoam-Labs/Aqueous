using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Tmds.DBus;

namespace Aqueous.Features.Network
{
    // NetworkManager D-Bus interface definitions

    [DBusInterface("org.freedesktop.NetworkManager")]
    public interface INetworkManager : IDBusObject
    {
        Task<ObjectPath> ActivateConnectionAsync(ObjectPath connection, ObjectPath device, ObjectPath specificObject);
        Task DeactivateConnectionAsync(ObjectPath activeConnection);
        Task<ObjectPath> AddAndActivateConnectionAsync(IDictionary<string, IDictionary<string, object>> connection, ObjectPath device, ObjectPath specificObject);
        Task<T> GetAsync<T>(string prop);
        Task SetAsync(string prop, object val);
        Task<IDictionary<string, object>> GetAllAsync();
        Task<ObjectPath[]> GetDevicesAsync();
    }

    [DBusInterface("org.freedesktop.NetworkManager.Device")]
    public interface INetworkDevice : IDBusObject
    {
        Task<T> GetAsync<T>(string prop);
        Task<IDictionary<string, object>> GetAllAsync();
    }

    [DBusInterface("org.freedesktop.NetworkManager.Device.Wireless")]
    public interface IWirelessDevice : IDBusObject
    {
        Task RequestScanAsync(IDictionary<string, object> options);
        Task<ObjectPath[]> GetAccessPointsAsync();
        Task<T> GetAsync<T>(string prop);
    }

    [DBusInterface("org.freedesktop.NetworkManager.AccessPoint")]
    public interface IAccessPoint : IDBusObject
    {
        Task<T> GetAsync<T>(string prop);
        Task<IDictionary<string, object>> GetAllAsync();
    }

    [DBusInterface("org.freedesktop.NetworkManager.Connection.Active")]
    public interface IActiveConnection : IDBusObject
    {
        Task<T> GetAsync<T>(string prop);
        Task<IDictionary<string, object>> GetAllAsync();
    }

    [DBusInterface("org.freedesktop.DBus.Properties")]
    public interface INmProperties : IDBusObject
    {
        Task<IDisposable> WatchPropertiesChangedAsync(
            Action<(string iface, IDictionary<string, object> changed, string[] invalidated)> handler,
            Action<Exception>? onError = null);
    }

    public class NetworkBackend : IDisposable
    {
        private Connection? _connection;
        private INetworkManager? _networkManager;
        private IDisposable? _propsWatch;
        private readonly List<IDisposable> _devicePropsWatches = new();
        private uint _devicesChangedDebounce;

        public bool IsConnected => _networkManager != null;

        public event Action? DevicesChanged;
        public event Action? StateChanged;

        public void ResetConnection()
        {
            _propsWatch?.Dispose();
            _propsWatch = null;
            foreach (var w in _devicePropsWatches)
                w.Dispose();
            _devicePropsWatches.Clear();
            if (_devicesChangedDebounce != 0)
            {
                GLib.Functions.SourceRemove(_devicesChangedDebounce);
                _devicesChangedDebounce = 0;
            }
            _networkManager = null;
            _connection?.Dispose();
            _connection = null;
        }

        public async Task ConnectAsync()
        {
            _connection = new Connection(Address.System);
            await _connection.ConnectAsync().WaitAsync(TimeSpan.FromSeconds(5));

            _networkManager = _connection.CreateProxy<INetworkManager>(
                "org.freedesktop.NetworkManager", new ObjectPath("/org/freedesktop/NetworkManager"));

            // Watch NM properties for global state changes
            var nmProps = _connection.CreateProxy<INmProperties>(
                "org.freedesktop.NetworkManager", new ObjectPath("/org/freedesktop/NetworkManager"));
            _propsWatch = await nmProps.WatchPropertiesChangedAsync(change =>
            {
                if (change.iface == "org.freedesktop.NetworkManager")
                    RaiseDevicesChangedDebounced();
            });

            await SubscribeDevicePropertiesAsync();
        }

        public async Task SubscribeDevicePropertiesAsync()
        {
            foreach (var w in _devicePropsWatches)
                w.Dispose();
            _devicePropsWatches.Clear();

            if (_connection == null || _networkManager == null) return;

            try
            {
                var devicePaths = await _networkManager.GetDevicesAsync();
                foreach (var path in devicePaths)
                {
                    try
                    {
                        var devProps = _connection.CreateProxy<INmProperties>(
                            "org.freedesktop.NetworkManager", path);
                        var watch = await devProps.WatchPropertiesChangedAsync(change =>
                        {
                            RaiseDevicesChangedDebounced();
                        });
                        _devicePropsWatches.Add(watch);
                    }
                    catch (Exception ex)
                    {
                        Console.Error.WriteLine($"[Network] SubscribeDeviceProps({path}) error: {ex.Message}");
                    }
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[Network] SubscribeDevicePropertiesAsync error: {ex.Message}");
            }
        }

        public async Task<List<NetworkDevice>> GetDevicesAsync()
        {
            var devices = new List<NetworkDevice>();
            if (_connection == null || _networkManager == null) return devices;

            try
            {
                var devicePaths = await _networkManager.GetDevicesAsync();
                foreach (var path in devicePaths)
                {
                    try
                    {
                        var dev = _connection.CreateProxy<INetworkDevice>(
                            "org.freedesktop.NetworkManager", path);
                        var props = await dev.GetAllAsync();

                        var deviceType = props.TryGetValue("DeviceType", out var dt) && dt is uint dtu
                            ? dtu switch { 1 => NetworkDeviceType.Ethernet, 2 => NetworkDeviceType.Wifi, _ => NetworkDeviceType.Unknown }
                            : NetworkDeviceType.Unknown;

                        // Skip loopback and other non-physical devices
                        if (deviceType == NetworkDeviceType.Unknown) continue;

                        var state = props.TryGetValue("State", out var st) && st is uint stu
                            ? stu switch
                            {
                                100 => NetworkConnectionState.Connected,
                                40 or 50 or 60 or 70 or 80 or 90 => NetworkConnectionState.Connecting,
                                110 or 120 => NetworkConnectionState.Deactivating,
                                _ => NetworkConnectionState.Disconnected
                            }
                            : NetworkConnectionState.Unknown;

                        var iface = props.TryGetValue("Interface", out var ifv) ? ifv as string ?? "" : "";

                        // Get active connection name
                        var activeConnName = "";
                        if (props.TryGetValue("ActiveConnection", out var acPath) && acPath is ObjectPath acp && acp.ToString() != "/")
                        {
                            try
                            {
                                var ac = _connection.CreateProxy<IActiveConnection>(
                                    "org.freedesktop.NetworkManager", acp);
                                var acId = await ac.GetAsync<string>("Id");
                                activeConnName = acId ?? "";
                            }
                            catch { }
                        }

                        // Get signal strength for Wi-Fi
                        var signalStrength = -1;
                        if (deviceType == NetworkDeviceType.Wifi)
                        {
                            try
                            {
                                var wireless = _connection.CreateProxy<IWirelessDevice>(
                                    "org.freedesktop.NetworkManager", path);
                                var activeAp = await wireless.GetAsync<ObjectPath>("ActiveAccessPoint");
                                if (activeAp.ToString() != "/")
                                {
                                    var ap = _connection.CreateProxy<IAccessPoint>(
                                        "org.freedesktop.NetworkManager", activeAp);
                                    var strength = await ap.GetAsync<byte>("Strength");
                                    signalStrength = strength;
                                }
                                else
                                {
                                    signalStrength = 0;
                                }
                            }
                            catch { signalStrength = 0; }
                        }

                        devices.Add(new NetworkDevice(iface, deviceType, state, activeConnName, signalStrength));
                    }
                    catch (Exception ex)
                    {
                        Console.Error.WriteLine($"[Network] GetDevicesAsync device error: {ex.Message}");
                    }
                }
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Network] GetDevicesAsync error: {ex.Message}"); }

            return devices;
        }

        public async Task<List<WifiAccessPoint>> GetAccessPointsAsync(string deviceInterface)
        {
            var accessPoints = new List<WifiAccessPoint>();
            if (_connection == null || _networkManager == null) return accessPoints;

            try
            {
                var devicePaths = await _networkManager.GetDevicesAsync();
                foreach (var path in devicePaths)
                {
                    var dev = _connection.CreateProxy<INetworkDevice>(
                        "org.freedesktop.NetworkManager", path);
                    var iface = await dev.GetAsync<string>("Interface");
                    if (iface != deviceInterface) continue;

                    var wireless = _connection.CreateProxy<IWirelessDevice>(
                        "org.freedesktop.NetworkManager", path);
                    var apPaths = await wireless.GetAccessPointsAsync();

                    foreach (var apPath in apPaths)
                    {
                        try
                        {
                            var ap = _connection.CreateProxy<IAccessPoint>(
                                "org.freedesktop.NetworkManager", apPath);
                            var apProps = await ap.GetAllAsync();

                            var ssidBytes = apProps.TryGetValue("Ssid", out var sb) ? sb as byte[] : null;
                            var ssid = ssidBytes != null ? System.Text.Encoding.UTF8.GetString(ssidBytes) : "";
                            if (string.IsNullOrEmpty(ssid)) continue;

                            var strength = apProps.TryGetValue("Strength", out var s) && s is byte b ? (int)b : 0;

                            // WpaFlags or RsnFlags != 0 means secured
                            var wpaFlags = apProps.TryGetValue("WpaFlags", out var wf) && wf is uint wfu ? wfu : 0u;
                            var rsnFlags = apProps.TryGetValue("RsnFlags", out var rf) && rf is uint rfu ? rfu : 0u;
                            var isSecured = wpaFlags != 0 || rsnFlags != 0;

                            accessPoints.Add(new WifiAccessPoint(ssid, strength, isSecured, apPath.ToString()));
                        }
                        catch (Exception ex)
                        {
                            Console.Error.WriteLine($"[Network] GetAccessPointsAsync AP error: {ex.Message}");
                        }
                    }
                    break;
                }
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Network] GetAccessPointsAsync error: {ex.Message}"); }

            return accessPoints;
        }

        public async Task<bool> GetWirelessEnabledAsync()
        {
            try
            {
                if (_networkManager == null) return false;
                return await _networkManager.GetAsync<bool>("WirelessEnabled");
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[Network] GetWirelessEnabledAsync error: {ex.Message}");
                return false;
            }
        }

        public async Task SetWirelessEnabledAsync(bool enabled)
        {
            try
            {
                if (_networkManager == null) return;
                await _networkManager.SetAsync("WirelessEnabled", enabled);
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Network] SetWirelessEnabledAsync error: {ex.Message}"); }
        }

        public async Task<bool> GetNetworkingEnabledAsync()
        {
            try
            {
                if (_networkManager == null) return false;
                return await _networkManager.GetAsync<bool>("NetworkingEnabled");
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[Network] GetNetworkingEnabledAsync error: {ex.Message}");
                return false;
            }
        }

        public async Task RequestScanAsync(string deviceInterface)
        {
            if (_connection == null || _networkManager == null) return;
            try
            {
                var devicePaths = await _networkManager.GetDevicesAsync();
                foreach (var path in devicePaths)
                {
                    var dev = _connection.CreateProxy<INetworkDevice>(
                        "org.freedesktop.NetworkManager", path);
                    var iface = await dev.GetAsync<string>("Interface");
                    if (iface != deviceInterface) continue;

                    var wireless = _connection.CreateProxy<IWirelessDevice>(
                        "org.freedesktop.NetworkManager", path);
                    await wireless.RequestScanAsync(new Dictionary<string, object>());
                    break;
                }
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Network] RequestScanAsync error: {ex.Message}"); }
        }

        public async Task ActivateConnectionAsync(string accessPointPath, string devicePath)
        {
            if (_connection == null || _networkManager == null) return;
            try
            {
                await _networkManager.ActivateConnectionAsync(
                    new ObjectPath("/"),
                    new ObjectPath(devicePath),
                    new ObjectPath(accessPointPath));
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Network] ActivateConnectionAsync error: {ex.Message}"); }
        }

        public async Task ConnectToNewWifiAsync(string ssid, string password, string devicePath)
        {
            if (_connection == null || _networkManager == null) return;
            try
            {
                var connection = new Dictionary<string, IDictionary<string, object>>
                {
                    ["connection"] = new Dictionary<string, object>
                    {
                        ["type"] = "802-11-wireless",
                        ["id"] = ssid
                    },
                    ["802-11-wireless"] = new Dictionary<string, object>
                    {
                        ["ssid"] = System.Text.Encoding.UTF8.GetBytes(ssid),
                        ["mode"] = "infrastructure"
                    },
                    ["802-11-wireless-security"] = new Dictionary<string, object>
                    {
                        ["key-mgmt"] = "wpa-psk",
                        ["psk"] = password
                    }
                };

                await _networkManager.AddAndActivateConnectionAsync(
                    connection,
                    new ObjectPath(devicePath),
                    new ObjectPath("/"));
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Network] ConnectToNewWifiAsync error: {ex.Message}"); }
        }

        public async Task DeactivateConnectionAsync(string activeConnectionPath)
        {
            if (_networkManager == null) return;
            try
            {
                await _networkManager.DeactivateConnectionAsync(new ObjectPath(activeConnectionPath));
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Network] DeactivateConnectionAsync error: {ex.Message}"); }
        }

        public async Task<ObjectPath?> FindDevicePathAsync(string deviceInterface)
        {
            if (_connection == null || _networkManager == null) return null;
            try
            {
                var devicePaths = await _networkManager.GetDevicesAsync();
                foreach (var path in devicePaths)
                {
                    var dev = _connection.CreateProxy<INetworkDevice>(
                        "org.freedesktop.NetworkManager", path);
                    var iface = await dev.GetAsync<string>("Interface");
                    if (iface == deviceInterface) return path;
                }
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Network] FindDevicePathAsync error: {ex.Message}"); }
            return null;
        }

        private void RaiseDevicesChangedDebounced()
        {
            if (_devicesChangedDebounce != 0)
                GLib.Functions.SourceRemove(_devicesChangedDebounce);
            _devicesChangedDebounce = GLib.Functions.TimeoutAdd(0, 1000, () =>
            {
                _devicesChangedDebounce = 0;
                DevicesChanged?.Invoke();
                StateChanged?.Invoke();
                return false;
            });
        }

        public void Dispose()
        {
            if (_devicesChangedDebounce != 0)
            {
                GLib.Functions.SourceRemove(_devicesChangedDebounce);
                _devicesChangedDebounce = 0;
            }
            _propsWatch?.Dispose();
            foreach (var w in _devicePropsWatches)
                w.Dispose();
            _devicePropsWatches.Clear();
            _connection?.Dispose();
        }
    }
}
