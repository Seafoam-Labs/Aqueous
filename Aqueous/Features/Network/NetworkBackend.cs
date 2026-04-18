using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Aqueous.Features.Network
{
    public class NetworkBackend : IDisposable
    {
        private Process? _monitorProcess;
        private CancellationTokenSource? _monitorCts;
        private uint _devicesChangedDebounce;

        public bool IsConnected { get; private set; }

        public event Action? DevicesChanged;
        public event Action? StateChanged;

        public void ResetConnection()
        {
            StopMonitor();
            IsConnected = false;
            if (_devicesChangedDebounce != 0)
            {
                GLib.Functions.SourceRemove(_devicesChangedDebounce);
                _devicesChangedDebounce = 0;
            }
        }

        public async Task ConnectAsync()
        {
            var result = await RunAsync("networkctl", "list --no-pager --no-legend");
            if (result.ExitCode != 0)
                throw new Exception("networkctl not available or systemd-networkd not running");

            IsConnected = true;
            StartMonitor();
        }

        private void StartMonitor()
        {
            StopMonitor();
            _monitorCts = new CancellationTokenSource();

            _monitorProcess = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = "networkctl",
                    Arguments = "monitor",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                },
                EnableRaisingEvents = true
            };

            _monitorProcess.Start();

            var ct = _monitorCts.Token;
            Task.Run(async () =>
            {
                try
                {
                    var reader = _monitorProcess.StandardOutput;
                    while (!ct.IsCancellationRequested)
                    {
                        var line = await reader.ReadLineAsync(ct);
                        if (line == null) break;
                        RaiseDevicesChangedDebounced();
                    }
                }
                catch (OperationCanceledException) { }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"[Network] Monitor error: {ex.Message}");
                }
            }, ct);
        }

        private void StopMonitor()
        {
            _monitorCts?.Cancel();
            if (_monitorProcess != null)
            {
                try
                {
                    if (!_monitorProcess.HasExited)
                        _monitorProcess.Kill();
                    _monitorProcess.Dispose();
                }
                catch { }
                _monitorProcess = null;
            }
            _monitorCts?.Dispose();
            _monitorCts = null;
        }

        private void RaiseDevicesChangedDebounced()
        {
            GLib.Functions.IdleAdd(0, () =>
            {
                if (_devicesChangedDebounce != 0)
                    GLib.Functions.SourceRemove(_devicesChangedDebounce);

                _devicesChangedDebounce = GLib.Functions.TimeoutAdd(0, 300, () =>
                {
                    _devicesChangedDebounce = 0;
                    DevicesChanged?.Invoke();
                    StateChanged?.Invoke();
                    return false;
                });
                return false;
            });
        }

        public async Task<List<NetworkDevice>> GetDevicesAsync()
        {
            var devices = new List<NetworkDevice>();
            if (!IsConnected) return devices;

            try
            {
                var result = await RunAsync("networkctl", "list --no-pager --no-legend");
                if (result.ExitCode != 0) return devices;

                foreach (var line in result.Output.Split('\n'))
                {
                    var trimmed = line.Trim();
                    if (string.IsNullOrEmpty(trimmed)) continue;

                    // Format: IDX NAME TYPE OPERATIONAL SETUP
                    var parts = Regex.Split(trimmed, @"\s+");
                    if (parts.Length < 4) continue;

                    var name = parts[1];
                    var type = parts[2];
                    var operational = parts[3];

                    var deviceType = type switch
                    {
                        "ether" => NetworkDeviceType.Ethernet,
                        "wlan" => NetworkDeviceType.Wifi,
                        _ => NetworkDeviceType.Unknown
                    };

                    if (deviceType == NetworkDeviceType.Unknown) continue;

                    var state = operational switch
                    {
                        "routable" or "carrier" => NetworkConnectionState.Connected,
                        "degraded" => NetworkConnectionState.Connecting,
                        "dormant" or "no-carrier" or "off" => NetworkConnectionState.Disconnected,
                        _ => NetworkConnectionState.Disconnected
                    };

                    var activeConnName = "";
                    var signalStrength = -1;

                    if (deviceType == NetworkDeviceType.Wifi)
                    {
                        signalStrength = 0;
                        // Get connected network name and signal from iwctl
                        try
                        {
                            var iwResult = await RunAsync("iwctl", $"station {name} show");
                            if (iwResult.ExitCode == 0)
                            {
                                foreach (var iwLine in iwResult.Output.Split('\n'))
                                {
                                    var iwTrimmed = iwLine.Trim();
                                    if (iwTrimmed.StartsWith("Connected network"))
                                    {
                                        activeConnName = iwTrimmed["Connected network".Length..].Trim();
                                    }
                                }

                                // Get signal strength from scan results if connected
                                if (!string.IsNullOrEmpty(activeConnName))
                                {
                                    var netResult = await RunAsync("iwctl", $"station {name} get-networks");
                                    if (netResult.ExitCode == 0)
                                    {
                                        foreach (var netLine in netResult.Output.Split('\n'))
                                        {
                                            if (netLine.Contains(activeConnName))
                                            {
                                                signalStrength = ParseSignalBars(netLine);
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        catch (Exception ex)
                        {
                            Console.Error.WriteLine($"[Network] iwctl station show error: {ex.Message}");
                        }
                    }
                    else if (state == NetworkConnectionState.Connected)
                    {
                        activeConnName = name;
                    }

                    devices.Add(new NetworkDevice(name, deviceType, state, activeConnName, signalStrength));
                }
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Network] GetDevicesAsync error: {ex.Message}"); }

            return devices;
        }

        public async Task<List<WifiAccessPoint>> GetAccessPointsAsync(string deviceInterface)
        {
            var accessPoints = new List<WifiAccessPoint>();
            if (!IsConnected) return accessPoints;

            try
            {
                var result = await RunAsync("iwctl", $"station {deviceInterface} get-networks");
                if (result.ExitCode != 0) return accessPoints;

                var lines = result.Output.Split('\n');
                var pastHeader = false;
                var headerDashCount = 0;

                foreach (var line in lines)
                {
                    if (line.Contains("--------"))
                    {
                        headerDashCount++;
                        if (headerDashCount >= 2)
                            pastHeader = true;
                        continue;
                    }

                    if (!pastHeader || string.IsNullOrWhiteSpace(line)) continue;

                    // Lines look like:
                    //   >   MyHomeWifi                      psk               ****
                    //       CoffeeShop                      open              ***
                    var trimmed = line.TrimStart();
                    var isConnected = trimmed.StartsWith(">");
                    if (isConnected)
                        trimmed = trimmed[1..].TrimStart();

                    // Parse from the right: signal bars, then security, then network name
                    var parts = Regex.Split(trimmed.TrimEnd(), @"\s{2,}");
                    if (parts.Length < 3) continue;

                    var networkName = parts[0].Trim();
                    var security = parts[1].Trim().ToLower();
                    var signalStr = parts[2].Trim();

                    if (string.IsNullOrEmpty(networkName)) continue;

                    var isSecured = security != "open";
                    var strength = ParseSignalBars(signalStr);

                    accessPoints.Add(new WifiAccessPoint(networkName, strength, isSecured, networkName));
                }
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Network] GetAccessPointsAsync error: {ex.Message}"); }

            return accessPoints;
        }

        public async Task<bool> GetWirelessEnabledAsync()
        {
            try
            {
                var result = await RunAsync("iwctl", "device list");
                if (result.ExitCode != 0) return false;

                foreach (var line in result.Output.Split('\n'))
                {
                    var trimmed = line.Trim();
                    if (trimmed.Contains("on") && !trimmed.Contains("Powered") && !trimmed.Contains("----"))
                    {
                        // Check if any device line has "on" in the Powered column
                        var parts = Regex.Split(trimmed, @"\s{2,}");
                        if (parts.Length >= 3)
                        {
                            // Name, Address, Powered, Adapter, Mode
                            foreach (var part in parts)
                            {
                                if (part.Trim().Equals("on", StringComparison.OrdinalIgnoreCase))
                                    return true;
                            }
                        }
                    }
                }
                return false;
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
                // Find the wlan device name first
                var devices = await GetDevicesAsync();
                var wlanDevice = devices.FirstOrDefault(d => d.DeviceType == NetworkDeviceType.Wifi);
                if (wlanDevice == null) return;

                await RunAsync("iwctl", $"device {wlanDevice.Interface} set-property Powered {(enabled ? "on" : "off")}");
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Network] SetWirelessEnabledAsync error: {ex.Message}"); }
        }

        public async Task<bool> GetNetworkingEnabledAsync()
        {
            try
            {
                var result = await RunAsync("networkctl", "list --no-pager --no-legend");
                if (result.ExitCode != 0) return false;

                foreach (var line in result.Output.Split('\n'))
                {
                    var trimmed = line.Trim();
                    if (string.IsNullOrEmpty(trimmed)) continue;
                    var parts = Regex.Split(trimmed, @"\s+");
                    if (parts.Length >= 4)
                    {
                        var operational = parts[3];
                        if (operational == "routable" || operational == "carrier")
                            return true;
                    }
                }
                return false;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[Network] GetNetworkingEnabledAsync error: {ex.Message}");
                return false;
            }
        }

        public async Task RequestScanAsync(string deviceInterface)
        {
            try
            {
                await RunAsync("iwctl", $"station {deviceInterface} scan");
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Network] RequestScanAsync error: {ex.Message}"); }
        }

        public async Task ActivateConnectionAsync(string networkName, string deviceInterface)
        {
            try
            {
                await RunAsync("iwctl", $"station {deviceInterface} connect \"{networkName}\"");
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Network] ActivateConnectionAsync error: {ex.Message}"); }
        }

        public async Task ConnectToNewWifiAsync(string ssid, string password, string deviceInterface)
        {
            try
            {
                await RunAsync("iwctl", $"station {deviceInterface} connect \"{ssid}\" --passphrase \"{password}\"");
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Network] ConnectToNewWifiAsync error: {ex.Message}"); }
        }

        public async Task DeactivateConnectionAsync(string deviceInterface)
        {
            try
            {
                await RunAsync("iwctl", $"station {deviceInterface} disconnect");
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Network] DeactivateConnectionAsync error: {ex.Message}"); }
        }

        public Task<string?> FindDevicePathAsync(string deviceInterface)
        {
            // With networkctl/iwctl, we just use the interface name directly
            return Task.FromResult<string?>(deviceInterface);
        }

        private static int ParseSignalBars(string input)
        {
            // Count asterisks for signal strength: **** = ~100, *** = ~75, ** = ~50, * = ~25
            var stars = input.Count(c => c == '*');
            return stars switch
            {
                >= 4 => 100,
                3 => 75,
                2 => 50,
                1 => 25,
                _ => 0
            };
        }

        public void Dispose()
        {
            ResetConnection();
            GC.SuppressFinalize(this);
        }

        private static async Task<(int ExitCode, string Output)> RunAsync(string command, string args)
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = command,
                    Arguments = args,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                }
            };

            process.Start();
            var output = await process.StandardOutput.ReadToEndAsync();
            await process.WaitForExitAsync();
            return (process.ExitCode, output);
        }
    }
}
