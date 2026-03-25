using System;
using System.Runtime.InteropServices;
namespace Aqueous.Bindings.AstalPowerProfiles
{
    public static unsafe partial class AstalPowerProfilesInterop
    {
        private const string LibName = "libastal-power-profiles.so";
        // AstalPowerProfilesPowerProfiles
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_power_profiles_power_profiles_get_type();
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalPowerProfilesPowerProfiles *")]
        public static partial _AstalPowerProfilesPowerProfiles* astal_power_profiles_get_default();
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalPowerProfilesPowerProfiles *")]
        public static partial _AstalPowerProfilesPowerProfiles* astal_power_profiles_power_profiles_get_default();
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalPowerProfilesPowerProfiles *")]
        public static partial _AstalPowerProfilesPowerProfiles* astal_power_profiles_power_profiles_new();
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalPowerProfilesPowerProfiles *")]
        public static partial _AstalPowerProfilesPowerProfiles* astal_power_profiles_power_profiles_construct([NativeTypeName("GType")] nuint object_type);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_power_profiles_power_profiles_hold_profile([NativeTypeName("AstalPowerProfilesPowerProfiles *")] _AstalPowerProfilesPowerProfiles* self, [NativeTypeName("const gchar *")] sbyte* profile, [NativeTypeName("const gchar *")] sbyte* reason, [NativeTypeName("const gchar *")] sbyte* application_id);
        [LibraryImport(LibName)]
        public static partial void astal_power_profiles_power_profiles_release_profile([NativeTypeName("AstalPowerProfilesPowerProfiles *")] _AstalPowerProfilesPowerProfiles* self, [NativeTypeName("guint")] uint cookie);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_power_profiles_power_profiles_get_active_profile([NativeTypeName("AstalPowerProfilesPowerProfiles *")] _AstalPowerProfilesPowerProfiles* self);
        [LibraryImport(LibName)]
        public static partial void astal_power_profiles_power_profiles_set_active_profile([NativeTypeName("AstalPowerProfilesPowerProfiles *")] _AstalPowerProfilesPowerProfiles* self, [NativeTypeName("const gchar *")] sbyte* value);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_power_profiles_power_profiles_get_icon_name([NativeTypeName("AstalPowerProfilesPowerProfiles *")] _AstalPowerProfilesPowerProfiles* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar **")]
        public static partial sbyte** astal_power_profiles_power_profiles_get_actions([NativeTypeName("AstalPowerProfilesPowerProfiles *")] _AstalPowerProfilesPowerProfiles* self, [NativeTypeName("gint *")] int* result_length1);
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalPowerProfilesHold *")]
        public static partial _AstalPowerProfilesHold* astal_power_profiles_power_profiles_get_active_profile_holds([NativeTypeName("AstalPowerProfilesPowerProfiles *")] _AstalPowerProfilesPowerProfiles* self, [NativeTypeName("gint *")] int* result_length1);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_power_profiles_power_profiles_get_performance_degraded([NativeTypeName("AstalPowerProfilesPowerProfiles *")] _AstalPowerProfilesPowerProfiles* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalPowerProfilesProfile *")]
        public static partial _AstalPowerProfilesProfile* astal_power_profiles_power_profiles_get_profiles([NativeTypeName("AstalPowerProfilesPowerProfiles *")] _AstalPowerProfilesPowerProfiles* self, [NativeTypeName("gint *")] int* result_length1);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_power_profiles_power_profiles_get_version([NativeTypeName("AstalPowerProfilesPowerProfiles *")] _AstalPowerProfilesPowerProfiles* self);
        // AstalPowerProfilesHold
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_power_profiles_hold_get_type();
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalPowerProfilesHold *")]
        public static partial _AstalPowerProfilesHold* astal_power_profiles_hold_dup([NativeTypeName("const AstalPowerProfilesHold *")] _AstalPowerProfilesHold* self);
        [LibraryImport(LibName)]
        public static partial void astal_power_profiles_hold_free([NativeTypeName("AstalPowerProfilesHold *")] _AstalPowerProfilesHold* self);
        [LibraryImport(LibName)]
        public static partial void astal_power_profiles_hold_copy([NativeTypeName("const AstalPowerProfilesHold *")] _AstalPowerProfilesHold* self, [NativeTypeName("AstalPowerProfilesHold *")] _AstalPowerProfilesHold* dest);
        [LibraryImport(LibName)]
        public static partial void astal_power_profiles_hold_destroy([NativeTypeName("AstalPowerProfilesHold *")] _AstalPowerProfilesHold* self);
        // AstalPowerProfilesProfile
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_power_profiles_profile_get_type();
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalPowerProfilesProfile *")]
        public static partial _AstalPowerProfilesProfile* astal_power_profiles_profile_dup([NativeTypeName("const AstalPowerProfilesProfile *")] _AstalPowerProfilesProfile* self);
        [LibraryImport(LibName)]
        public static partial void astal_power_profiles_profile_free([NativeTypeName("AstalPowerProfilesProfile *")] _AstalPowerProfilesProfile* self);
        [LibraryImport(LibName)]
        public static partial void astal_power_profiles_profile_copy([NativeTypeName("const AstalPowerProfilesProfile *")] _AstalPowerProfilesProfile* self, [NativeTypeName("AstalPowerProfilesProfile *")] _AstalPowerProfilesProfile* dest);
        [LibraryImport(LibName)]
        public static partial void astal_power_profiles_profile_destroy([NativeTypeName("AstalPowerProfilesProfile *")] _AstalPowerProfilesProfile* self);
    }
}
