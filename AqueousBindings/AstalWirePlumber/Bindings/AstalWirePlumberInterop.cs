using System;
using System.Runtime.InteropServices;
namespace Aqueous.Bindings.AstalWirePlumber
{
    public static unsafe partial class AstalWirePlumberInterop
    {
        private const string LibName = "libastal-wireplumber.so";

        // AstalWpWp
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_wp_wp_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpWp *")]
        public static partial _AstalWpWp* astal_wp_wp_get_default();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpWp *")]
        public static partial _AstalWpWp* astal_wp_get_default();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpAudio *")]
        public static partial _AstalWpAudio* astal_wp_wp_get_audio([NativeTypeName("AstalWpWp *")] _AstalWpWp* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpVideo *")]
        public static partial _AstalWpVideo* astal_wp_wp_get_video([NativeTypeName("AstalWpWp *")] _AstalWpWp* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpAudio *")]
        public static partial _AstalWpAudio* astal_wp_audio_new([NativeTypeName("AstalWpWp *")] _AstalWpWp* wp);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpVideo *")]
        public static partial _AstalWpVideo* astal_wp_video_new([NativeTypeName("AstalWpWp *")] _AstalWpWp* wp);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpNode *")]
        public static partial _AstalWpNode* astal_wp_wp_get_node([NativeTypeName("AstalWpWp *")] _AstalWpWp* self, [NativeTypeName("guint")] uint id);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wp_wp_get_nodes([NativeTypeName("AstalWpWp *")] _AstalWpWp* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpNode *")]
        public static partial _AstalWpNode* astal_wp_wp_get_node_by_serial([NativeTypeName("AstalWpWp *")] _AstalWpWp* self, [NativeTypeName("gint")] int serial);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpDevice *")]
        public static partial _AstalWpDevice* astal_wp_wp_get_device([NativeTypeName("AstalWpWp *")] _AstalWpWp* self, [NativeTypeName("guint")] uint id);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wp_wp_get_devices([NativeTypeName("AstalWpWp *")] _AstalWpWp* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpEndpoint *")]
        public static partial _AstalWpEndpoint* astal_wp_wp_get_default_speaker([NativeTypeName("AstalWpWp *")] _AstalWpWp* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpEndpoint *")]
        public static partial _AstalWpEndpoint* astal_wp_wp_get_default_microphone([NativeTypeName("AstalWpWp *")] _AstalWpWp* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpScale")]
        public static partial int astal_wp_wp_get_scale([NativeTypeName("AstalWpWp *")] _AstalWpWp* self);

        [LibraryImport(LibName)]
        public static partial void astal_wp_wp_set_scale([NativeTypeName("AstalWpWp *")] _AstalWpWp* self, [NativeTypeName("AstalWpScale")] int scale);

        // AstalWpAudio
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_wp_audio_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpEndpoint *")]
        public static partial _AstalWpEndpoint* astal_wp_audio_get_speaker([NativeTypeName("AstalWpAudio *")] _AstalWpAudio* self, [NativeTypeName("guint")] uint id);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpEndpoint *")]
        public static partial _AstalWpEndpoint* astal_wp_audio_get_microphone([NativeTypeName("AstalWpAudio *")] _AstalWpAudio* self, [NativeTypeName("guint")] uint id);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpStream *")]
        public static partial _AstalWpStream* astal_wp_audio_get_recorder([NativeTypeName("AstalWpAudio *")] _AstalWpAudio* self, [NativeTypeName("guint")] uint id);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpStream *")]
        public static partial _AstalWpStream* astal_wp_audio_get_stream([NativeTypeName("AstalWpAudio *")] _AstalWpAudio* self, [NativeTypeName("guint")] uint id);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpNode *")]
        public static partial _AstalWpNode* astal_wp_audio_get_node([NativeTypeName("AstalWpAudio *")] _AstalWpAudio* self, [NativeTypeName("guint")] uint id);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpDevice *")]
        public static partial _AstalWpDevice* astal_wp_audio_get_device([NativeTypeName("AstalWpAudio *")] _AstalWpAudio* self, [NativeTypeName("guint")] uint id);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpEndpoint *")]
        public static partial _AstalWpEndpoint* astal_wp_audio_get_default_speaker([NativeTypeName("AstalWpAudio *")] _AstalWpAudio* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpEndpoint *")]
        public static partial _AstalWpEndpoint* astal_wp_audio_get_default_microphone([NativeTypeName("AstalWpAudio *")] _AstalWpAudio* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wp_audio_get_microphones([NativeTypeName("AstalWpAudio *")] _AstalWpAudio* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wp_audio_get_speakers([NativeTypeName("AstalWpAudio *")] _AstalWpAudio* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wp_audio_get_recorders([NativeTypeName("AstalWpAudio *")] _AstalWpAudio* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wp_audio_get_streams([NativeTypeName("AstalWpAudio *")] _AstalWpAudio* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wp_audio_get_devices([NativeTypeName("AstalWpAudio *")] _AstalWpAudio* self);

        // AstalWpVideo
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_wp_video_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpEndpoint *")]
        public static partial _AstalWpEndpoint* astal_wp_video_get_source([NativeTypeName("AstalWpVideo *")] _AstalWpVideo* self, [NativeTypeName("guint")] uint id);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpEndpoint *")]
        public static partial _AstalWpEndpoint* astal_wp_video_get_sink([NativeTypeName("AstalWpVideo *")] _AstalWpVideo* self, [NativeTypeName("guint")] uint id);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpStream *")]
        public static partial _AstalWpStream* astal_wp_video_get_recorder([NativeTypeName("AstalWpVideo *")] _AstalWpVideo* self, [NativeTypeName("guint")] uint id);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpStream *")]
        public static partial _AstalWpStream* astal_wp_video_get_stream([NativeTypeName("AstalWpVideo *")] _AstalWpVideo* self, [NativeTypeName("guint")] uint id);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpDevice *")]
        public static partial _AstalWpDevice* astal_wp_video_get_device([NativeTypeName("AstalWpVideo *")] _AstalWpVideo* self, [NativeTypeName("guint")] uint id);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wp_video_get_sources([NativeTypeName("AstalWpVideo *")] _AstalWpVideo* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wp_video_get_sinks([NativeTypeName("AstalWpVideo *")] _AstalWpVideo* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wp_video_get_recorders([NativeTypeName("AstalWpVideo *")] _AstalWpVideo* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wp_video_get_streams([NativeTypeName("AstalWpVideo *")] _AstalWpVideo* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wp_video_get_devices([NativeTypeName("AstalWpVideo *")] _AstalWpVideo* self);

        // AstalWpNode
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_wp_node_get_type();

        [LibraryImport(LibName)]
        public static partial void astal_wp_node_set_volume([NativeTypeName("AstalWpNode *")] _AstalWpNode* self, [NativeTypeName("gdouble")] double volume);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_wp_node_get_volume([NativeTypeName("AstalWpNode *")] _AstalWpNode* self);

        [LibraryImport(LibName)]
        public static partial void astal_wp_node_set_mute([NativeTypeName("AstalWpNode *")] _AstalWpNode* self, [NativeTypeName("gboolean")] int mute);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_wp_node_get_mute([NativeTypeName("AstalWpNode *")] _AstalWpNode* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_wp_node_get_lock_channels([NativeTypeName("AstalWpNode *")] _AstalWpNode* self);

        [LibraryImport(LibName)]
        public static partial void astal_wp_node_set_lock_channels([NativeTypeName("AstalWpNode *")] _AstalWpNode* self, [NativeTypeName("gboolean")] int lock_channels);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpMediaClass")]
        public static partial int astal_wp_node_get_media_class([NativeTypeName("AstalWpNode *")] _AstalWpNode* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("guint")]
        public static partial uint astal_wp_node_get_id([NativeTypeName("AstalWpNode *")] _AstalWpNode* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_wp_node_get_description([NativeTypeName("AstalWpNode *")] _AstalWpNode* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_wp_node_get_name([NativeTypeName("AstalWpNode *")] _AstalWpNode* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_wp_node_get_icon([NativeTypeName("AstalWpNode *")] _AstalWpNode* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_wp_node_get_volume_icon([NativeTypeName("AstalWpNode *")] _AstalWpNode* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_wp_node_get_serial([NativeTypeName("AstalWpNode *")] _AstalWpNode* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_wp_node_get_path([NativeTypeName("AstalWpNode *")] _AstalWpNode* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpNodeState")]
        public static partial int astal_wp_node_get_state([NativeTypeName("AstalWpNode *")] _AstalWpNode* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wp_node_get_channels([NativeTypeName("AstalWpNode *")] _AstalWpNode* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_wp_node_get_pw_property([NativeTypeName("AstalWpNode *")] _AstalWpNode* self, [NativeTypeName("const gchar *")] sbyte* key);

        // AstalWpEndpoint
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_wp_endpoint_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("guint")]
        public static partial uint astal_wp_endpoint_get_device_id([NativeTypeName("AstalWpEndpoint *")] _AstalWpEndpoint* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpDevice *")]
        public static partial _AstalWpDevice* astal_wp_endpoint_get_device([NativeTypeName("AstalWpEndpoint *")] _AstalWpEndpoint* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_wp_endpoint_get_is_default([NativeTypeName("AstalWpEndpoint *")] _AstalWpEndpoint* self);

        [LibraryImport(LibName)]
        public static partial void astal_wp_endpoint_set_is_default([NativeTypeName("AstalWpEndpoint *")] _AstalWpEndpoint* self, [NativeTypeName("gboolean")] int is_default);

        [LibraryImport(LibName)]
        [return: NativeTypeName("guint")]
        public static partial uint astal_wp_endpoint_get_route_id([NativeTypeName("AstalWpEndpoint *")] _AstalWpEndpoint* self);

        [LibraryImport(LibName)]
        public static partial void astal_wp_endpoint_set_route_id([NativeTypeName("AstalWpEndpoint *")] _AstalWpEndpoint* self, [NativeTypeName("guint")] uint route_id);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpRoute *")]
        public static partial _AstalWpRoute* astal_wp_endpoint_get_route([NativeTypeName("AstalWpEndpoint *")] _AstalWpEndpoint* self);

        [LibraryImport(LibName)]
        public static partial void astal_wp_endpoint_set_route([NativeTypeName("AstalWpEndpoint *")] _AstalWpEndpoint* self, [NativeTypeName("AstalWpRoute *")] _AstalWpRoute* route);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wp_endpoint_get_routes([NativeTypeName("AstalWpEndpoint *")] _AstalWpEndpoint* self);

        // AstalWpStream
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_wp_stream_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpMediaRole")]
        public static partial int astal_wp_stream_get_media_role([NativeTypeName("AstalWpStream *")] _AstalWpStream* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpMediaCategory")]
        public static partial int astal_wp_stream_get_media_category([NativeTypeName("AstalWpStream *")] _AstalWpStream* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_wp_stream_get_target_serial([NativeTypeName("AstalWpStream *")] _AstalWpStream* self);

        [LibraryImport(LibName)]
        public static partial void astal_wp_stream_set_target_serial([NativeTypeName("AstalWpStream *")] _AstalWpStream* self, [NativeTypeName("gint")] int serial);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpEndpoint *")]
        public static partial _AstalWpEndpoint* astal_wp_stream_get_target_endpoint([NativeTypeName("AstalWpStream *")] _AstalWpStream* self);

        [LibraryImport(LibName)]
        public static partial void astal_wp_stream_set_target_endpoint([NativeTypeName("AstalWpStream *")] _AstalWpStream* self, [NativeTypeName("AstalWpEndpoint *")] _AstalWpEndpoint* target);

        // AstalWpDevice
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_wp_device_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("guint")]
        public static partial uint astal_wp_device_get_id([NativeTypeName("AstalWpDevice *")] _AstalWpDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_wp_device_get_description([NativeTypeName("AstalWpDevice *")] _AstalWpDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_wp_device_get_icon([NativeTypeName("AstalWpDevice *")] _AstalWpDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpDeviceType")]
        public static partial int astal_wp_device_get_device_type([NativeTypeName("AstalWpDevice *")] _AstalWpDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_wp_device_get_form_factor([NativeTypeName("AstalWpDevice *")] _AstalWpDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpProfile *")]
        public static partial _AstalWpProfile* astal_wp_device_get_profile([NativeTypeName("AstalWpDevice *")] _AstalWpDevice* self, [NativeTypeName("gint")] int id);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wp_device_get_profiles([NativeTypeName("AstalWpDevice *")] _AstalWpDevice* self);

        [LibraryImport(LibName)]
        public static partial void astal_wp_device_set_active_profile_id([NativeTypeName("AstalWpDevice *")] _AstalWpDevice* self, int profile_id);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_wp_device_get_active_profile_id([NativeTypeName("AstalWpDevice *")] _AstalWpDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_wp_device_get_input_route_id([NativeTypeName("AstalWpDevice *")] _AstalWpDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_wp_device_get_output_route_id([NativeTypeName("AstalWpDevice *")] _AstalWpDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpRoute *")]
        public static partial _AstalWpRoute* astal_wp_device_get_route([NativeTypeName("AstalWpDevice *")] _AstalWpDevice* self, [NativeTypeName("gint")] int id);

        [LibraryImport(LibName)]
        public static partial void astal_wp_device_set_route([NativeTypeName("AstalWpDevice *")] _AstalWpDevice* self, [NativeTypeName("AstalWpRoute *")] _AstalWpRoute* route, [NativeTypeName("guint")] uint card_device);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wp_device_get_routes([NativeTypeName("AstalWpDevice *")] _AstalWpDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wp_device_get_input_routes([NativeTypeName("AstalWpDevice *")] _AstalWpDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wp_device_get_output_routes([NativeTypeName("AstalWpDevice *")] _AstalWpDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_wp_device_get_pw_property([NativeTypeName("AstalWpDevice *")] _AstalWpDevice* self, [NativeTypeName("const gchar *")] sbyte* key);

        // AstalWpProfile
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_wp_profile_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_wp_profile_get_index([NativeTypeName("AstalWpProfile *")] _AstalWpProfile* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_wp_profile_get_description([NativeTypeName("AstalWpProfile *")] _AstalWpProfile* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_wp_profile_get_name([NativeTypeName("AstalWpProfile *")] _AstalWpProfile* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpAvailable")]
        public static partial int astal_wp_profile_get_available([NativeTypeName("AstalWpProfile *")] _AstalWpProfile* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_wp_profile_get_priority([NativeTypeName("AstalWpProfile *")] _AstalWpProfile* self);

        // AstalWpRoute
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_wp_route_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_wp_route_get_index([NativeTypeName("AstalWpRoute *")] _AstalWpRoute* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_wp_route_get_description([NativeTypeName("AstalWpRoute *")] _AstalWpRoute* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_wp_route_get_name([NativeTypeName("AstalWpRoute *")] _AstalWpRoute* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpDirection")]
        public static partial int astal_wp_route_get_direction([NativeTypeName("AstalWpRoute *")] _AstalWpRoute* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWpAvailable")]
        public static partial int astal_wp_route_get_available([NativeTypeName("AstalWpRoute *")] _AstalWpRoute* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_wp_route_get_priority([NativeTypeName("AstalWpRoute *")] _AstalWpRoute* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_wp_route_get_device([NativeTypeName("AstalWpRoute *")] _AstalWpRoute* self);

        // AstalWpChannel
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_wp_channel_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_wp_channel_get_volume([NativeTypeName("AstalWpChannel *")] _AstalWpChannel* self);

        [LibraryImport(LibName)]
        public static partial void astal_wp_channel_set_volume([NativeTypeName("AstalWpChannel *")] _AstalWpChannel* self, [NativeTypeName("gdouble")] double volume);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_wp_channel_get_name([NativeTypeName("AstalWpChannel *")] _AstalWpChannel* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_wp_channel_get_volume_icon([NativeTypeName("AstalWpChannel *")] _AstalWpChannel* self);
    }
}
