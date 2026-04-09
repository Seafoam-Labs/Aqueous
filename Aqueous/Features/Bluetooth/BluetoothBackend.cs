using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Tmds.DBus;

namespace Aqueous.Features.Bluetooth
{
    // BlueZ D-Bus interface definitions

    [DBusInterface("org.bluez.Adapter1")]
    public interface IAdapter1 : IDBusObject
    {
        Task StartDiscoveryAsync();
        Task StopDiscoveryAsync();
        Task RemoveDeviceAsync(ObjectPath device);
        Task<T> GetAsync<T>(string prop);
        Task SetAsync(string prop, object val);
        Task<IDictionary<string, object>> GetAllAsync();
    }

    [DBusInterface("org.bluez.Device1")]
    public interface IDevice1 : IDBusObject
    {
        Task ConnectAsync();
        Task DisconnectAsync();
        Task PairAsync();
        Task<T> GetAsync<T>(string prop);
        Task<IDictionary<string, object>> GetAllAsync();
    }

    [DBusInterface("org.freedesktop.DBus.Properties")]
    public interface IProperties : IDBusObject
    {
        Task<IDisposable> WatchPropertiesChangedAsync(
            Action<(string iface, IDictionary<string, object> changed, string[] invalidated)> handler,
            Action<Exception>? onError = null);
    }

    [DBusInterface("org.freedesktop.DBus.ObjectManager")]
    public interface IObjectManager : IDBusObject
    {
        Task<IDictionary<ObjectPath, IDictionary<string, IDictionary<string, object>>>> GetManagedObjectsAsync();
        Task<IDisposable> WatchInterfacesAddedAsync(
            Action<(ObjectPath objectPath, IDictionary<string, IDictionary<string, object>> interfaces)> handler,
            Action<Exception>? onError = null);
        Task<IDisposable> WatchInterfacesRemovedAsync(
            Action<(ObjectPath objectPath, string[] interfaces)> handler,
            Action<Exception>? onError = null);
    }

    public class BluetoothBackend : IDisposable
    {
        private Connection? _connection;
        private IAdapter1? _adapter;
        private IObjectManager? _objectManager;
        private IDisposable? _addedWatch;
        private IDisposable? _removedWatch;
        private IDisposable? _propsWatch;
        private ObjectPath _adapterPath;

        public List<ObjectPath> AvailableAdapters { get; private set; } = new();

        public event Action? DevicesChanged;
        public event Action? AdapterStateChanged;

        public async Task ConnectAsync()
        {
            _connection = new Connection(Address.System);
            await _connection.ConnectAsync();

            _objectManager = _connection.CreateProxy<IObjectManager>(
                "org.bluez", new ObjectPath("/"));

            // Discover adapters dynamically
            var objects = await _objectManager.GetManagedObjectsAsync();
            AvailableAdapters = new List<ObjectPath>();
            foreach (var (path, interfaces) in objects)
            {
                if (interfaces.ContainsKey("org.bluez.Adapter1"))
                    AvailableAdapters.Add(path);
            }

            if (AvailableAdapters.Count == 0)
                throw new Exception("No Bluetooth adapter found via BlueZ");

            _adapterPath = AvailableAdapters[0];

            _adapter = _connection.CreateProxy<IAdapter1>(
                "org.bluez", _adapterPath);

            // Watch for added interfaces (devices + hot-plug adapters)
            _addedWatch = await _objectManager.WatchInterfacesAddedAsync(
                change =>
                {
                    if (change.interfaces.ContainsKey("org.bluez.Adapter1"))
                    {
                        if (!AvailableAdapters.Contains(change.objectPath))
                            AvailableAdapters.Add(change.objectPath);
                        // Auto-connect if we had no adapter
                        if (_adapter == null)
                        {
                            _adapterPath = change.objectPath;
                            _adapter = _connection?.CreateProxy<IAdapter1>("org.bluez", _adapterPath);
                            AdapterStateChanged?.Invoke();
                        }
                    }
                    DevicesChanged?.Invoke();
                },
                ex => Console.Error.WriteLine($"[Bluetooth] WatchInterfacesAdded error: {ex.Message}"));

            // Watch for removed interfaces (devices + hot-unplug adapters)
            _removedWatch = await _objectManager.WatchInterfacesRemovedAsync(
                change =>
                {
                    if (change.interfaces != null)
                    {
                        foreach (var iface in change.interfaces)
                        {
                            if (iface == "org.bluez.Adapter1")
                            {
                                AvailableAdapters.Remove(change.objectPath);
                                if (_adapterPath == change.objectPath)
                                {
                                    if (AvailableAdapters.Count > 0)
                                    {
                                        _adapterPath = AvailableAdapters[0];
                                        _adapter = _connection?.CreateProxy<IAdapter1>("org.bluez", _adapterPath);
                                    }
                                    else
                                    {
                                        _adapter = null;
                                    }
                                    AdapterStateChanged?.Invoke();
                                }
                                break;
                            }
                        }
                    }
                    DevicesChanged?.Invoke();
                },
                ex => Console.Error.WriteLine($"[Bluetooth] WatchInterfacesRemoved error: {ex.Message}"));

            await SubscribeAdapterPropertiesAsync();
        }

        private async Task SubscribeAdapterPropertiesAsync()
        {
            _propsWatch?.Dispose();
            if (_connection == null) return;

            var adapterProps = _connection.CreateProxy<IProperties>("org.bluez", _adapterPath);
            _propsWatch = await adapterProps.WatchPropertiesChangedAsync(change =>
            {
                if (change.iface == "org.bluez.Adapter1" && change.changed.ContainsKey("Powered"))
                    AdapterStateChanged?.Invoke();
            });
        }

        public async Task<bool> GetAdapterPoweredAsync()
        {
            try
            {
                if (_adapter == null) return false;
                return await _adapter.GetAsync<bool>("Powered");
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[Bluetooth] GetAdapterPoweredAsync error: {ex.Message}");
                return false;
            }
        }

        public async Task SetAdapterPoweredAsync(bool powered)
        {
            try
            {
                if (_adapter == null) return;
                await _adapter.SetAsync("Powered", powered);
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Bluetooth] SetAdapterPoweredAsync error: {ex.Message}"); }
        }

        public async Task<bool> GetDiscoveringAsync()
        {
            try
            {
                if (_adapter == null) return false;
                return await _adapter.GetAsync<bool>("Discovering");
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[Bluetooth] GetDiscoveringAsync error: {ex.Message}");
                return false;
            }
        }

        public async Task StartDiscoveryAsync()
        {
            try { if (_adapter != null) await _adapter.StartDiscoveryAsync(); }
            catch (Exception ex) { Console.Error.WriteLine($"[Bluetooth] StartDiscoveryAsync error: {ex.Message}"); }
        }

        public async Task StopDiscoveryAsync()
        {
            try { if (_adapter != null) await _adapter.StopDiscoveryAsync(); }
            catch (Exception ex) { Console.Error.WriteLine($"[Bluetooth] StopDiscoveryAsync error: {ex.Message}"); }
        }

        public async Task<List<BluetoothDevice>> GetDevicesAsync()
        {
            var devices = new List<BluetoothDevice>();
            if (_objectManager == null) return devices;

            try
            {
                var objects = await _objectManager.GetManagedObjectsAsync();
                foreach (var (path, interfaces) in objects)
                {
                    if (!interfaces.TryGetValue("org.bluez.Device1", out var props))
                        continue;

                    var address = props.TryGetValue("Address", out var a) ? a as string ?? "" : "";
                    var name = props.TryGetValue("Name", out var n) ? n as string ?? address : address;
                    var icon = props.TryGetValue("Icon", out var ic) ? ic as string ?? "bluetooth" : "bluetooth";
                    var paired = props.TryGetValue("Paired", out var p) && p is bool bp && bp;
                    var connected = props.TryGetValue("Connected", out var c) && c is bool bc && bc;
                    var trusted = props.TryGetValue("Trusted", out var t) && t is bool bt && bt;
                    var rssi = props.TryGetValue("RSSI", out var r) && r is short rs ? rs : (short)0;

                    var status = connected ? BluetoothDeviceStatus.Connected
                        : paired ? BluetoothDeviceStatus.Paired
                        : BluetoothDeviceStatus.Discovered;

                    devices.Add(new BluetoothDevice(address, name, icon, paired, connected, trusted, rssi, status));
                }
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Bluetooth] GetDevicesAsync error: {ex.Message}"); }

            return devices;
        }

        public async Task ConnectDeviceAsync(string address)
        {
            try
            {
                if (_connection == null) return;
                var path = AddressToPath(address);
                var device = _connection.CreateProxy<IDevice1>("org.bluez", path);
                await device.ConnectAsync();
                DevicesChanged?.Invoke();
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Bluetooth] ConnectDeviceAsync error: {ex.Message}"); }
        }

        public async Task DisconnectDeviceAsync(string address)
        {
            try
            {
                if (_connection == null) return;
                var path = AddressToPath(address);
                var device = _connection.CreateProxy<IDevice1>("org.bluez", path);
                await device.DisconnectAsync();
                DevicesChanged?.Invoke();
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Bluetooth] DisconnectDeviceAsync error: {ex.Message}"); }
        }

        public async Task PairDeviceAsync(string address)
        {
            try
            {
                if (_connection == null) return;
                var path = AddressToPath(address);
                var device = _connection.CreateProxy<IDevice1>("org.bluez", path);
                await device.PairAsync();
                DevicesChanged?.Invoke();
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Bluetooth] PairDeviceAsync error: {ex.Message}"); }
        }

        public async Task RemoveDeviceAsync(string address)
        {
            try
            {
                if (_adapter == null) return;
                var path = AddressToPath(address);
                await _adapter.RemoveDeviceAsync(path);
                DevicesChanged?.Invoke();
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Bluetooth] RemoveDeviceAsync error: {ex.Message}"); }
        }

        public async Task SetActiveAdapterAsync(ObjectPath path)
        {
            if (!AvailableAdapters.Contains(path))
                throw new ArgumentException($"Adapter {path} is not available");

            _adapterPath = path;
            _adapter = _connection?.CreateProxy<IAdapter1>("org.bluez", _adapterPath);

            await SubscribeAdapterPropertiesAsync();
            AdapterStateChanged?.Invoke();
        }

        private ObjectPath AddressToPath(string address)
        {
            return new ObjectPath($"{_adapterPath}/dev_{address.Replace(':', '_')}");
        }

        public void Dispose()
        {
            _addedWatch?.Dispose();
            _removedWatch?.Dispose();
            _propsWatch?.Dispose();
            _connection?.Dispose();
        }
    }
}
