using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalWl;
namespace Aqueous.Bindings.AstalWl.Services
{
    public unsafe class AstalWlOutput
    {
        private _AstalWlOutput* _handle;
        internal _AstalWlOutput* Handle => _handle;
        internal AstalWlOutput(_AstalWlOutput* handle)
        {
            _handle = handle;
        }
        public uint Id => AstalWlInterop.astal_wl_output_get_id(_handle);
        public string? Name => Marshal.PtrToStringAnsi((IntPtr)AstalWlInterop.astal_wl_output_get_name(_handle));
        public string? Description => Marshal.PtrToStringAnsi((IntPtr)AstalWlInterop.astal_wl_output_get_description(_handle));
        public string? Make => Marshal.PtrToStringAnsi((IntPtr)AstalWlInterop.astal_wl_output_get_make(_handle));
        public string? Model => Marshal.PtrToStringAnsi((IntPtr)AstalWlInterop.astal_wl_output_get_model(_handle));
        public int PhysicalWidth => AstalWlInterop.astal_wl_output_get_physical_width(_handle);
        public int PhysicalHeight => AstalWlInterop.astal_wl_output_get_physical_height(_handle);
        public double RefreshRate => AstalWlInterop.astal_wl_output_get_refresh_rate(_handle);
        public double Scale => AstalWlInterop.astal_wl_output_get_scale(_handle);
        public AstalWlOutputTransform Transform => (AstalWlOutputTransform)AstalWlInterop.astal_wl_output_get_transform(_handle);
        public AstalWlOutputSubpixel Subpixel => (AstalWlOutputSubpixel)AstalWlInterop.astal_wl_output_get_subpixel(_handle);
    }
}
