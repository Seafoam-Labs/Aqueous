using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Aqueous.Features.Bluetooth
{
    public class BluetoothBackend : IDisposable
    {
        private Process? _monitorProcess;
        private CancellationTokenSource? _monitorCts;
        private uint _devicesChangedDebounce;
        private bool _isScanning;

        public bool IsConnected { get; private set; }

        public event Action? DevicesChanged;
        public event Action? AdapterStateChanged;

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
            var result = await RunAsync("show");
            if (result.ExitCode != 0)
                throw new Exception("bluetoothctl not available or no adapter found");

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
                    FileName = "bluetoothctl",
                    Arguments = "",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    RedirectStandardInput = true,
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

                        if (line.Contains("NEW") || line.Contains("DEL") ||
                            line.Contains("CHG") || line.Contains("Connected:") ||
                            line.Contains("Paired:"))
                        {
                            if (line.Contains("Controller"))
                                GLib.Functions.IdleAdd(0, () => { AdapterStateChanged?.Invoke(); return false; });
                            else
                                RaiseDevicesChangedDebounced();
                        }
                    }
                }
                catch (OperationCanceledException) { }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"[Bluetooth] Monitor error: {ex.Message}");
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
                    return false;
                });
                return false;
            });
        }

        public async Task<bool> GetAdapterPoweredAsync()
        {
            var result = await RunAsync("show");
            if (result.ExitCode != 0) return false;
            return result.Output.Contains("Powered: yes");
        }

        public async Task SetAdapterPoweredAsync(bool powered)
        {
            await RunAsync(powered ? "power on" : "power off");
        }

        public async Task<bool> GetDiscoveringAsync()
        {
            var result = await RunAsync("show");
            if (result.ExitCode != 0) return false;
            return result.Output.Contains("Discovering: yes");
        }

        public async Task StartDiscoveryAsync()
        {
            if (_isScanning) return;
            _isScanning = true;
            await RunAsync("scan on");
        }

        public async Task StopDiscoveryAsync()
        {
            if (!_isScanning) return;
            _isScanning = false;
            await RunAsync("scan off");
        }

        public async Task<List<BluetoothDevice>> GetDevicesAsync()
        {
            var result = await RunAsync("devices");
            if (result.ExitCode != 0) return new List<BluetoothDevice>();

            var devices = new List<BluetoothDevice>();
            var deviceRegex = new Regex(@"Device\s+([\dA-Fa-f:]{17})\s+(.+)");

            foreach (var line in result.Output.Split('\n'))
            {
                var match = deviceRegex.Match(line);
                if (!match.Success) continue;

                var address = match.Groups[1].Value;
                var name = match.Groups[2].Value.Trim();

                try
                {
                    var info = await GetDeviceInfoAsync(address);
                    if (info != null)
                    {
                        devices.Add(info with { Name = string.IsNullOrEmpty(info.Name) ? name : info.Name });
                    }
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"[Bluetooth] Failed to get info for {address}: {ex.Message}");
                }
            }

            return devices;
        }

        private async Task<BluetoothDevice?> GetDeviceInfoAsync(string address)
        {
            var result = await RunAsync($"info {address}");
            if (result.ExitCode != 0) return null;

            var lines = result.Output.Split('\n');
            string name = address;
            string icon = "bluetooth";
            bool paired = false;
            bool connected = false;
            bool trusted = false;
            short rssi = 0;

            foreach (var line in lines)
            {
                var trimmed = line.Trim();
                if (trimmed.StartsWith("Name:"))
                    name = trimmed["Name:".Length..].Trim();
                else if (trimmed.StartsWith("Icon:"))
                    icon = trimmed["Icon:".Length..].Trim();
                else if (trimmed.StartsWith("Paired:"))
                    paired = trimmed.Contains("yes");
                else if (trimmed.StartsWith("Connected:"))
                    connected = trimmed.Contains("yes");
                else if (trimmed.StartsWith("Trusted:"))
                    trusted = trimmed.Contains("yes");
                else if (trimmed.StartsWith("RSSI:"))
                {
                    var rssiMatch = Regex.Match(trimmed, @"-?\d+");
                    if (rssiMatch.Success && short.TryParse(rssiMatch.Value, out var r))
                        rssi = r;
                }
            }

            var status = connected ? BluetoothDeviceStatus.Connected
                       : paired ? BluetoothDeviceStatus.Paired
                       : BluetoothDeviceStatus.Discovered;

            return new BluetoothDevice(address, name, icon, paired, connected, trusted, rssi, status);
        }

        public async Task ConnectDeviceAsync(string address)
        {
            await RunAsync($"connect {address}");
        }

        public async Task DisconnectDeviceAsync(string address)
        {
            await RunAsync($"disconnect {address}");
        }

        public async Task PairDeviceAsync(string address)
        {
            await RunAsync($"trust {address}");
            await RunAsync($"pair {address}");
        }

        public async Task RemoveDeviceAsync(string address)
        {
            await RunAsync($"remove {address}");
        }

        public void Dispose()
        {
            ResetConnection();
            GC.SuppressFinalize(this);
        }

        private static async Task<(int ExitCode, string Output)> RunAsync(string args)
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = "bluetoothctl",
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
