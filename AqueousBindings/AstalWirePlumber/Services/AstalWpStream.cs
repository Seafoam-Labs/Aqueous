using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalWirePlumber;

namespace Aqueous.Bindings.AstalWirePlumber.Services
{
    public unsafe class AstalWpStream
    {
        private _AstalWpStream* _handle;

        internal _AstalWpStream* Handle => _handle;

        internal AstalWpStream(_AstalWpStream* handle)
        {
            _handle = handle;
        }

        public AstalWpMediaRole MediaRole => (AstalWpMediaRole)AstalWirePlumberInterop.astal_wp_stream_get_media_role(_handle);

        public AstalWpMediaCategory MediaCategory => (AstalWpMediaCategory)AstalWirePlumberInterop.astal_wp_stream_get_media_category(_handle);

        public int TargetSerial
        {
            get => AstalWirePlumberInterop.astal_wp_stream_get_target_serial(_handle);
            set => AstalWirePlumberInterop.astal_wp_stream_set_target_serial(_handle, value);
        }

        public AstalWpEndpoint? TargetEndpoint
        {
            get
            {
                var ptr = AstalWirePlumberInterop.astal_wp_stream_get_target_endpoint(_handle);
                return ptr == null ? null : new AstalWpEndpoint(ptr);
            }
            set => AstalWirePlumberInterop.astal_wp_stream_set_target_endpoint(_handle, value == null ? null : value.Handle);
        }

        // Node properties (Stream extends Node in C)
        public uint Id => AstalWirePlumberInterop.astal_wp_node_get_id((_AstalWpNode*)_handle);

        public string? Description => Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_node_get_description((_AstalWpNode*)_handle));

        public string? Name => Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_node_get_name((_AstalWpNode*)_handle));

        public string? Icon => Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_node_get_icon((_AstalWpNode*)_handle));

        public string? VolumeIcon => Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_node_get_volume_icon((_AstalWpNode*)_handle));

        public int Serial => AstalWirePlumberInterop.astal_wp_node_get_serial((_AstalWpNode*)_handle);

        public string? Path => Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_node_get_path((_AstalWpNode*)_handle));

        public AstalWpNodeState State => (AstalWpNodeState)AstalWirePlumberInterop.astal_wp_node_get_state((_AstalWpNode*)_handle);

        public AstalWpMediaClass MediaClass => (AstalWpMediaClass)AstalWirePlumberInterop.astal_wp_node_get_media_class((_AstalWpNode*)_handle);

        public double Volume
        {
            get => AstalWirePlumberInterop.astal_wp_node_get_volume((_AstalWpNode*)_handle);
            set => AstalWirePlumberInterop.astal_wp_node_set_volume((_AstalWpNode*)_handle, value);
        }

        public bool Mute
        {
            get => AstalWirePlumberInterop.astal_wp_node_get_mute((_AstalWpNode*)_handle) != 0;
            set => AstalWirePlumberInterop.astal_wp_node_set_mute((_AstalWpNode*)_handle, value ? 1 : 0);
        }

        public bool LockChannels
        {
            get => AstalWirePlumberInterop.astal_wp_node_get_lock_channels((_AstalWpNode*)_handle) != 0;
            set => AstalWirePlumberInterop.astal_wp_node_set_lock_channels((_AstalWpNode*)_handle, value ? 1 : 0);
        }

        public string? GetPwProperty(string key)
        {
            fixed (byte* ptr = System.Text.Encoding.UTF8.GetBytes(key + '\0'))
                return Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_node_get_pw_property((_AstalWpNode*)_handle, (sbyte*)ptr));
        }
    }
}
