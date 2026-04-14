using System;
using Aqueous.Bindings.AstalPowerProfiles.Services;
namespace Aqueous.Features.PowerProfiles
{
    public class PowerProfilesBackend : IDisposable
    {
        private AstalPowerProfilesPowerProfiles? _profiles;
        public event Action? ProfileChanged;
        public void Start()
        {
            _profiles = AstalPowerProfilesPowerProfiles.GetDefault();
        }
        public string? ActiveProfile
        {
            get => _profiles?.ActiveProfile;
            set
            {
                if (_profiles != null && value != null)
                {
                    _profiles.ActiveProfile = value;
                    ProfileChanged?.Invoke();
                }
            }
        }
        public string? IconName => _profiles?.IconName;
        public string? PerformanceDegraded => _profiles?.PerformanceDegraded;
        public AstalPowerProfilesProfile[]? Profiles => _profiles?.Profiles;
        public AstalPowerProfilesHold[]? ActiveHolds => _profiles?.ActiveProfileHolds;
        public void CycleProfile()
        {
            var order = new[] { "power-saver", "balanced", "performance" };
            var current = ActiveProfile ?? "balanced";
            var idx = Array.IndexOf(order, current);
            if (idx < 0) idx = 1; // default to balanced
            ActiveProfile = order[(idx + 1) % order.Length];
        }
        public void Dispose()
        {
            _profiles = null;
        }
    }
}
