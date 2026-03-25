using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalWirePlumber;

namespace Aqueous.Bindings.AstalWirePlumber.Services
{
    public unsafe class AstalWpVideo
    {
        private _AstalWpVideo* _handle;

        internal _AstalWpVideo* Handle => _handle;

        internal AstalWpVideo(_AstalWpVideo* handle)
        {
            _handle = handle;
        }

        public AstalWpEndpoint? GetSource(uint id)
        {
            var ptr = AstalWirePlumberInterop.astal_wp_video_get_source(_handle, id);
            return ptr == null ? null : new AstalWpEndpoint(ptr);
        }

        public AstalWpEndpoint? GetSink(uint id)
        {
            var ptr = AstalWirePlumberInterop.astal_wp_video_get_sink(_handle, id);
            return ptr == null ? null : new AstalWpEndpoint(ptr);
        }

        public AstalWpStream? GetRecorder(uint id)
        {
            var ptr = AstalWirePlumberInterop.astal_wp_video_get_recorder(_handle, id);
            return ptr == null ? null : new AstalWpStream(ptr);
        }

        public AstalWpStream? GetStream(uint id)
        {
            var ptr = AstalWirePlumberInterop.astal_wp_video_get_stream(_handle, id);
            return ptr == null ? null : new AstalWpStream(ptr);
        }

        public AstalWpDevice? GetDevice(uint id)
        {
            var ptr = AstalWirePlumberInterop.astal_wp_video_get_device(_handle, id);
            return ptr == null ? null : new AstalWpDevice(ptr);
        }
    }
}
