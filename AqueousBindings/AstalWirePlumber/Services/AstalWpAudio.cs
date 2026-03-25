using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalWirePlumber;

namespace Aqueous.Bindings.AstalWirePlumber.Services
{
    public unsafe class AstalWpAudio
    {
        private _AstalWpAudio* _handle;

        internal _AstalWpAudio* Handle => _handle;

        internal AstalWpAudio(_AstalWpAudio* handle)
        {
            _handle = handle;
        }

        public AstalWpEndpoint? GetSpeaker(uint id)
        {
            var ptr = AstalWirePlumberInterop.astal_wp_audio_get_speaker(_handle, id);
            return ptr == null ? null : new AstalWpEndpoint(ptr);
        }

        public AstalWpEndpoint? GetMicrophone(uint id)
        {
            var ptr = AstalWirePlumberInterop.astal_wp_audio_get_microphone(_handle, id);
            return ptr == null ? null : new AstalWpEndpoint(ptr);
        }

        public AstalWpStream? GetRecorder(uint id)
        {
            var ptr = AstalWirePlumberInterop.astal_wp_audio_get_recorder(_handle, id);
            return ptr == null ? null : new AstalWpStream(ptr);
        }

        public AstalWpStream? GetStream(uint id)
        {
            var ptr = AstalWirePlumberInterop.astal_wp_audio_get_stream(_handle, id);
            return ptr == null ? null : new AstalWpStream(ptr);
        }

        public AstalWpNode? GetNode(uint id)
        {
            var ptr = AstalWirePlumberInterop.astal_wp_audio_get_node(_handle, id);
            return ptr == null ? null : new AstalWpNode(ptr);
        }

        public AstalWpDevice? GetDevice(uint id)
        {
            var ptr = AstalWirePlumberInterop.astal_wp_audio_get_device(_handle, id);
            return ptr == null ? null : new AstalWpDevice(ptr);
        }

        public AstalWpEndpoint? DefaultSpeaker
        {
            get
            {
                var ptr = AstalWirePlumberInterop.astal_wp_audio_get_default_speaker(_handle);
                return ptr == null ? null : new AstalWpEndpoint(ptr);
            }
        }

        public AstalWpEndpoint? DefaultMicrophone
        {
            get
            {
                var ptr = AstalWirePlumberInterop.astal_wp_audio_get_default_microphone(_handle);
                return ptr == null ? null : new AstalWpEndpoint(ptr);
            }
        }
    }
}
