using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalCava;
namespace Aqueous.Bindings.AstalCava.Services
{
    public unsafe class AstalCavaCava
    {
        private _AstalCavaCava* _handle;
        internal _AstalCavaCava* Handle => _handle;
        internal AstalCavaCava(_AstalCavaCava* handle)
        {
            _handle = handle;
        }
        public static AstalCavaCava? GetDefault()
        {
            var ptr = AstalCavaInterop.astal_cava_cava_get_default();
            return ptr == null ? null : new AstalCavaCava(ptr);
        }
        public bool Active
        {
            get => AstalCavaInterop.astal_cava_cava_get_active(_handle) != 0;
            set => AstalCavaInterop.astal_cava_cava_set_active(_handle, value ? 1 : 0);
        }
        public int Bars
        {
            get => AstalCavaInterop.astal_cava_cava_get_bars(_handle);
            set => AstalCavaInterop.astal_cava_cava_set_bars(_handle, value);
        }
        public bool Autosens
        {
            get => AstalCavaInterop.astal_cava_cava_get_autosens(_handle) != 0;
            set => AstalCavaInterop.astal_cava_cava_set_autosens(_handle, value ? 1 : 0);
        }
        public bool Stereo
        {
            get => AstalCavaInterop.astal_cava_cava_get_stereo(_handle) != 0;
            set => AstalCavaInterop.astal_cava_cava_set_stereo(_handle, value ? 1 : 0);
        }
        public double NoiseReduction
        {
            get => AstalCavaInterop.astal_cava_cava_get_noise_reduction(_handle);
            set => AstalCavaInterop.astal_cava_cava_set_noise_reduction(_handle, value);
        }
        public int Framerate
        {
            get => AstalCavaInterop.astal_cava_cava_get_framerate(_handle);
            set => AstalCavaInterop.astal_cava_cava_set_framerate(_handle, value);
        }
        public AstalCavaInput Input
        {
            get => (AstalCavaInput)AstalCavaInterop.astal_cava_cava_get_input(_handle);
            set => AstalCavaInterop.astal_cava_cava_set_input(_handle, (int)value);
        }
        public string? Source
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalCavaInterop.astal_cava_cava_get_source(_handle));
            set
            {
                var ptr = (sbyte*)Marshal.StringToHGlobalAnsi(value);
                try
                {
                    AstalCavaInterop.astal_cava_cava_set_source(_handle, ptr);
                }
                finally
                {
                    Marshal.FreeHGlobal((IntPtr)ptr);
                }
            }
        }
        public int Channels
        {
            get => AstalCavaInterop.astal_cava_cava_get_channels(_handle);
            set => AstalCavaInterop.astal_cava_cava_set_channels(_handle, value);
        }
        public int LowCutoff
        {
            get => AstalCavaInterop.astal_cava_cava_get_low_cutoff(_handle);
            set => AstalCavaInterop.astal_cava_cava_set_low_cutoff(_handle, value);
        }
        public int HighCutoff
        {
            get => AstalCavaInterop.astal_cava_cava_get_high_cutoff(_handle);
            set => AstalCavaInterop.astal_cava_cava_set_high_cutoff(_handle, value);
        }
        public int Samplerate
        {
            get => AstalCavaInterop.astal_cava_cava_get_samplerate(_handle);
            set => AstalCavaInterop.astal_cava_cava_set_samplerate(_handle, value);
        }
    }
}
