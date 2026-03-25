using System;
using System.Runtime.InteropServices;
namespace Aqueous.Bindings.AstalNetwork
{
    public static unsafe partial class AstalNetworkInterop
    {
        private const string LibName = "libastal-network.so";

        // AstalNetworkAccessPoint
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_network_access_point_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("GPtrArray *")]
        public static partial _GPtrArray* astal_network_access_point_get_connections([NativeTypeName("AstalNetworkAccessPoint *")] _AstalNetworkAccessPoint* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_network_access_point_get_path([NativeTypeName("AstalNetworkAccessPoint *")] _AstalNetworkAccessPoint* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("guint")]
        public static partial uint astal_network_access_point_get_bandwidth([NativeTypeName("AstalNetworkAccessPoint *")] _AstalNetworkAccessPoint* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_network_access_point_get_bssid([NativeTypeName("AstalNetworkAccessPoint *")] _AstalNetworkAccessPoint* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("guint")]
        public static partial uint astal_network_access_point_get_frequency([NativeTypeName("AstalNetworkAccessPoint *")] _AstalNetworkAccessPoint* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_network_access_point_get_last_seen([NativeTypeName("AstalNetworkAccessPoint *")] _AstalNetworkAccessPoint* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("guint")]
        public static partial uint astal_network_access_point_get_max_bitrate([NativeTypeName("AstalNetworkAccessPoint *")] _AstalNetworkAccessPoint* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("guint8")]
        public static partial byte astal_network_access_point_get_strength([NativeTypeName("AstalNetworkAccessPoint *")] _AstalNetworkAccessPoint* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_network_access_point_get_icon_name([NativeTypeName("AstalNetworkAccessPoint *")] _AstalNetworkAccessPoint* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("NM80211Mode")]
        public static partial int astal_network_access_point_get_mode([NativeTypeName("AstalNetworkAccessPoint *")] _AstalNetworkAccessPoint* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("NM80211ApFlags")]
        public static partial int astal_network_access_point_get_flags([NativeTypeName("AstalNetworkAccessPoint *")] _AstalNetworkAccessPoint* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("NM80211ApSecurityFlags")]
        public static partial int astal_network_access_point_get_rsn_flags([NativeTypeName("AstalNetworkAccessPoint *")] _AstalNetworkAccessPoint* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("NM80211ApSecurityFlags")]
        public static partial int astal_network_access_point_get_wpa_flags([NativeTypeName("AstalNetworkAccessPoint *")] _AstalNetworkAccessPoint* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_network_access_point_get_requires_password([NativeTypeName("AstalNetworkAccessPoint *")] _AstalNetworkAccessPoint* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_network_access_point_get_ssid([NativeTypeName("AstalNetworkAccessPoint *")] _AstalNetworkAccessPoint* self);

        // AstalNetworkNetwork
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_network_network_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNetworkNetwork *")]
        public static partial _AstalNetworkNetwork* astal_network_get_default();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNetworkNetwork *")]
        public static partial _AstalNetworkNetwork* astal_network_network_get_default();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNetworkNetwork *")]
        public static partial _AstalNetworkNetwork* astal_network_network_new();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNetworkNetwork *")]
        public static partial _AstalNetworkNetwork* astal_network_network_construct([NativeTypeName("GType")] nuint object_type);

        [LibraryImport(LibName)]
        [return: NativeTypeName("NMClient *")]
        public static partial _NMClient* astal_network_network_get_client([NativeTypeName("AstalNetworkNetwork *")] _AstalNetworkNetwork* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNetworkWifi *")]
        public static partial _AstalNetworkWifi* astal_network_network_get_wifi([NativeTypeName("AstalNetworkNetwork *")] _AstalNetworkNetwork* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNetworkWired *")]
        public static partial _AstalNetworkWired* astal_network_network_get_wired([NativeTypeName("AstalNetworkNetwork *")] _AstalNetworkNetwork* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNetworkPrimary")]
        public static partial int astal_network_network_get_primary([NativeTypeName("AstalNetworkNetwork *")] _AstalNetworkNetwork* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNetworkConnectivity")]
        public static partial int astal_network_network_get_connectivity([NativeTypeName("AstalNetworkNetwork *")] _AstalNetworkNetwork* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNetworkState")]
        public static partial int astal_network_network_get_state([NativeTypeName("AstalNetworkNetwork *")] _AstalNetworkNetwork* self);

        // Enum helpers
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_network_primary_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_network_primary_to_string([NativeTypeName("AstalNetworkPrimary")] int self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNetworkPrimary")]
        public static partial int astal_network_primary_from_connection_type([NativeTypeName("const gchar *")] sbyte* type);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_network_connectivity_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_network_connectivity_to_string([NativeTypeName("AstalNetworkConnectivity")] int self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_network_state_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_network_state_to_string([NativeTypeName("AstalNetworkState")] int self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_network_device_state_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_network_device_state_to_string([NativeTypeName("AstalNetworkDeviceState")] int self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_network_internet_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNetworkInternet")]
        public static partial int astal_network_internet_from_device([NativeTypeName("NMDevice *")] _NMDevice* device);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_network_internet_to_string([NativeTypeName("AstalNetworkInternet")] int self);

        // AstalNetworkWifi
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_network_wifi_get_type();

        [LibraryImport(LibName)]
        public static partial void astal_network_wifi_scan([NativeTypeName("AstalNetworkWifi *")] _AstalNetworkWifi* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("NMDeviceWifi *")]
        public static partial _NMDeviceWifi* astal_network_wifi_get_device([NativeTypeName("AstalNetworkWifi *")] _AstalNetworkWifi* self);

        [LibraryImport(LibName)]
        public static partial void astal_network_wifi_set_device([NativeTypeName("AstalNetworkWifi *")] _AstalNetworkWifi* self, [NativeTypeName("NMDeviceWifi *")] _NMDeviceWifi* value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("NMActiveConnection *")]
        public static partial _NMActiveConnection* astal_network_wifi_get_active_connection([NativeTypeName("AstalNetworkWifi *")] _AstalNetworkWifi* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNetworkAccessPoint *")]
        public static partial _AstalNetworkAccessPoint* astal_network_wifi_get_active_access_point([NativeTypeName("AstalNetworkWifi *")] _AstalNetworkWifi* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_network_wifi_get_access_points([NativeTypeName("AstalNetworkWifi *")] _AstalNetworkWifi* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_network_wifi_get_enabled([NativeTypeName("AstalNetworkWifi *")] _AstalNetworkWifi* self);

        [LibraryImport(LibName)]
        public static partial void astal_network_wifi_set_enabled([NativeTypeName("AstalNetworkWifi *")] _AstalNetworkWifi* self, [NativeTypeName("gboolean")] int value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNetworkInternet")]
        public static partial int astal_network_wifi_get_internet([NativeTypeName("AstalNetworkWifi *")] _AstalNetworkWifi* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("guint")]
        public static partial uint astal_network_wifi_get_bandwidth([NativeTypeName("AstalNetworkWifi *")] _AstalNetworkWifi* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_network_wifi_get_ssid([NativeTypeName("AstalNetworkWifi *")] _AstalNetworkWifi* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("guint8")]
        public static partial byte astal_network_wifi_get_strength([NativeTypeName("AstalNetworkWifi *")] _AstalNetworkWifi* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("guint")]
        public static partial uint astal_network_wifi_get_frequency([NativeTypeName("AstalNetworkWifi *")] _AstalNetworkWifi* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNetworkDeviceState")]
        public static partial int astal_network_wifi_get_state([NativeTypeName("AstalNetworkWifi *")] _AstalNetworkWifi* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_network_wifi_get_icon_name([NativeTypeName("AstalNetworkWifi *")] _AstalNetworkWifi* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_network_wifi_get_is_hotspot([NativeTypeName("AstalNetworkWifi *")] _AstalNetworkWifi* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_network_wifi_get_scanning([NativeTypeName("AstalNetworkWifi *")] _AstalNetworkWifi* self);

        // AstalNetworkWired
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_network_wired_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("NMDeviceEthernet *")]
        public static partial _NMDeviceEthernet* astal_network_wired_get_device([NativeTypeName("AstalNetworkWired *")] _AstalNetworkWired* self);

        [LibraryImport(LibName)]
        public static partial void astal_network_wired_set_device([NativeTypeName("AstalNetworkWired *")] _AstalNetworkWired* self, [NativeTypeName("NMDeviceEthernet *")] _NMDeviceEthernet* value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("guint")]
        public static partial uint astal_network_wired_get_speed([NativeTypeName("AstalNetworkWired *")] _AstalNetworkWired* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNetworkInternet")]
        public static partial int astal_network_wired_get_internet([NativeTypeName("AstalNetworkWired *")] _AstalNetworkWired* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNetworkDeviceState")]
        public static partial int astal_network_wired_get_state([NativeTypeName("AstalNetworkWired *")] _AstalNetworkWired* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_network_wired_get_icon_name([NativeTypeName("AstalNetworkWired *")] _AstalNetworkWired* self);
    }
}
