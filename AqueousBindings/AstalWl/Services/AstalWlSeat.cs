using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalWl;
namespace Aqueous.Bindings.AstalWl.Services
{
    public unsafe class AstalWlSeat
    {
        private _AstalWlSeat* _handle;
        internal _AstalWlSeat* Handle => _handle;
        internal AstalWlSeat(_AstalWlSeat* handle)
        {
            _handle = handle;
        }
        public uint Id => AstalWlInterop.astal_wl_seat_get_id(_handle);
        public string? Name => Marshal.PtrToStringAnsi((IntPtr)AstalWlInterop.astal_wl_seat_get_name(_handle));
        public AstalWlSeatCapabilities Capabilities => (AstalWlSeatCapabilities)AstalWlInterop.astal_wl_seat_get_capabilities(_handle);
    }
}
