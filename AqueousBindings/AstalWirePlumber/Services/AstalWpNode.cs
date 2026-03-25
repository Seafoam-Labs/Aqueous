using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalWirePlumber;

namespace Aqueous.Bindings.AstalWirePlumber.Services
{
    public unsafe class AstalWpNode
    {
        private _AstalWpNode* _handle;

        internal _AstalWpNode* Handle => _handle;

        internal AstalWpNode(_AstalWpNode* handle)
        {
            _handle = handle;
        }

        public uint Id => AstalWirePlumberInterop.astal_wp_node_get_id(_handle);

        public string? Description => Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_node_get_description(_handle));

        public string? Name => Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_node_get_name(_handle));

        public string? Icon => Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_node_get_icon(_handle));

        public string? VolumeIcon => Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_node_get_volume_icon(_handle));

        public int Serial => AstalWirePlumberInterop.astal_wp_node_get_serial(_handle);

        public string? Path => Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_node_get_path(_handle));

        public AstalWpNodeState State => (AstalWpNodeState)AstalWirePlumberInterop.astal_wp_node_get_state(_handle);

        public AstalWpMediaClass MediaClass => (AstalWpMediaClass)AstalWirePlumberInterop.astal_wp_node_get_media_class(_handle);

        public double Volume
        {
            get => AstalWirePlumberInterop.astal_wp_node_get_volume(_handle);
            set => AstalWirePlumberInterop.astal_wp_node_set_volume(_handle, value);
        }

        public bool Mute
        {
            get => AstalWirePlumberInterop.astal_wp_node_get_mute(_handle) != 0;
            set => AstalWirePlumberInterop.astal_wp_node_set_mute(_handle, value ? 1 : 0);
        }

        public bool LockChannels
        {
            get => AstalWirePlumberInterop.astal_wp_node_get_lock_channels(_handle) != 0;
            set => AstalWirePlumberInterop.astal_wp_node_set_lock_channels(_handle, value ? 1 : 0);
        }

        public string? GetPwProperty(string key)
        {
            fixed (byte* ptr = System.Text.Encoding.UTF8.GetBytes(key + '\0'))
                return Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_node_get_pw_property(_handle, (sbyte*)ptr));
        }
    }
}
