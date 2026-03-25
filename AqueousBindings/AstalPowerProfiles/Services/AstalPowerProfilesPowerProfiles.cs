using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalPowerProfiles;
namespace Aqueous.Bindings.AstalPowerProfiles.Services
{
    public unsafe class AstalPowerProfilesPowerProfiles
    {
        private _AstalPowerProfilesPowerProfiles* _handle;
        internal _AstalPowerProfilesPowerProfiles* Handle => _handle;
        public AstalPowerProfilesPowerProfiles()
        {
            _handle = AstalPowerProfilesInterop.astal_power_profiles_power_profiles_new();
        }
        internal AstalPowerProfilesPowerProfiles(_AstalPowerProfilesPowerProfiles* handle)
        {
            _handle = handle;
        }
        public static AstalPowerProfilesPowerProfiles GetDefault()
        {
            return new AstalPowerProfilesPowerProfiles(AstalPowerProfilesInterop.astal_power_profiles_get_default());
        }
        public int HoldProfile(string profile, string reason, string applicationId)
        {
            fixed (byte* pProfile = System.Text.Encoding.UTF8.GetBytes(profile + '\0'))
            fixed (byte* pReason = System.Text.Encoding.UTF8.GetBytes(reason + '\0'))
            fixed (byte* pAppId = System.Text.Encoding.UTF8.GetBytes(applicationId + '\0'))
                return AstalPowerProfilesInterop.astal_power_profiles_power_profiles_hold_profile(_handle, (sbyte*)pProfile, (sbyte*)pReason, (sbyte*)pAppId);
        }
        public void ReleaseProfile(uint cookie) => AstalPowerProfilesInterop.astal_power_profiles_power_profiles_release_profile(_handle, cookie);
        public string? ActiveProfile
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalPowerProfilesInterop.astal_power_profiles_power_profiles_get_active_profile(_handle));
            set
            {
                fixed (byte* ptr = System.Text.Encoding.UTF8.GetBytes((value ?? "") + '\0'))
                    AstalPowerProfilesInterop.astal_power_profiles_power_profiles_set_active_profile(_handle, (sbyte*)ptr);
            }
        }
        public string? IconName => Marshal.PtrToStringAnsi((IntPtr)AstalPowerProfilesInterop.astal_power_profiles_power_profiles_get_icon_name(_handle));
        public string[]? Actions
        {
            get
            {
                int length;
                sbyte** ptr = AstalPowerProfilesInterop.astal_power_profiles_power_profiles_get_actions(_handle, &length);
                if (ptr == null) return null;
                var result = new string[length];
                for (int i = 0; i < length; i++)
                    result[i] = Marshal.PtrToStringAnsi((IntPtr)ptr[i]) ?? "";
                return result;
            }
        }
        public AstalPowerProfilesHold[]? ActiveProfileHolds
        {
            get
            {
                int length;
                _AstalPowerProfilesHold* ptr = AstalPowerProfilesInterop.astal_power_profiles_power_profiles_get_active_profile_holds(_handle, &length);
                if (ptr == null) return null;
                var result = new AstalPowerProfilesHold[length];
                for (int i = 0; i < length; i++)
                    result[i] = new AstalPowerProfilesHold(&ptr[i]);
                return result;
            }
        }
        public string? PerformanceDegraded => Marshal.PtrToStringAnsi((IntPtr)AstalPowerProfilesInterop.astal_power_profiles_power_profiles_get_performance_degraded(_handle));
        public AstalPowerProfilesProfile[]? Profiles
        {
            get
            {
                int length;
                _AstalPowerProfilesProfile* ptr = AstalPowerProfilesInterop.astal_power_profiles_power_profiles_get_profiles(_handle, &length);
                if (ptr == null) return null;
                var result = new AstalPowerProfilesProfile[length];
                for (int i = 0; i < length; i++)
                    result[i] = new AstalPowerProfilesProfile(&ptr[i]);
                return result;
            }
        }
        public string? Version => Marshal.PtrToStringAnsi((IntPtr)AstalPowerProfilesInterop.astal_power_profiles_power_profiles_get_version(_handle));
    }
}
