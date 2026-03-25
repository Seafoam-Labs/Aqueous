using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalWirePlumber;

namespace Aqueous.Bindings.AstalWirePlumber.Services
{
    public unsafe class AstalWpWp
    {
        private _AstalWpWp* _handle;

        internal _AstalWpWp* Handle => _handle;

        internal AstalWpWp(_AstalWpWp* handle)
        {
            _handle = handle;
        }

        public static AstalWpWp? GetDefault()
        {
            var ptr = AstalWirePlumberInterop.astal_wp_wp_get_default();
            return ptr == null ? null : new AstalWpWp(ptr);
        }

        public AstalWpAudio? Audio
        {
            get
            {
                var ptr = AstalWirePlumberInterop.astal_wp_wp_get_audio(_handle);
                return ptr == null ? null : new AstalWpAudio(ptr);
            }
        }

        public AstalWpVideo? Video
        {
            get
            {
                var ptr = AstalWirePlumberInterop.astal_wp_wp_get_video(_handle);
                return ptr == null ? null : new AstalWpVideo(ptr);
            }
        }

        public AstalWpNode? GetNode(uint id)
        {
            var ptr = AstalWirePlumberInterop.astal_wp_wp_get_node(_handle, id);
            return ptr == null ? null : new AstalWpNode(ptr);
        }

        public AstalWpNode? GetNodeBySerial(int serial)
        {
            var ptr = AstalWirePlumberInterop.astal_wp_wp_get_node_by_serial(_handle, serial);
            return ptr == null ? null : new AstalWpNode(ptr);
        }

        public AstalWpDevice? GetDevice(uint id)
        {
            var ptr = AstalWirePlumberInterop.astal_wp_wp_get_device(_handle, id);
            return ptr == null ? null : new AstalWpDevice(ptr);
        }

        public AstalWpEndpoint? DefaultSpeaker
        {
            get
            {
                var ptr = AstalWirePlumberInterop.astal_wp_wp_get_default_speaker(_handle);
                return ptr == null ? null : new AstalWpEndpoint(ptr);
            }
        }

        public AstalWpEndpoint? DefaultMicrophone
        {
            get
            {
                var ptr = AstalWirePlumberInterop.astal_wp_wp_get_default_microphone(_handle);
                return ptr == null ? null : new AstalWpEndpoint(ptr);
            }
        }

        public AstalWpScale Scale
        {
            get => (AstalWpScale)AstalWirePlumberInterop.astal_wp_wp_get_scale(_handle);
            set => AstalWirePlumberInterop.astal_wp_wp_set_scale(_handle, (int)value);
        }
    }
}
