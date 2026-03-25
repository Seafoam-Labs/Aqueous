using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalWl;
namespace Aqueous.Bindings.AstalWl.Services
{
    public unsafe class AstalWlRegistry
    {
        private _AstalWlRegistry* _handle;
        internal _AstalWlRegistry* Handle => _handle;
        internal AstalWlRegistry(_AstalWlRegistry* handle)
        {
            _handle = handle;
        }
        public static AstalWlRegistry? GetDefault()
        {
            var ptr = AstalWlInterop.astal_wl_registry_get_default();
            return ptr == null ? null : new AstalWlRegistry(ptr);
        }
        public AstalWlOutput? GetOutputById(uint id)
        {
            var ptr = AstalWlInterop.astal_wl_registry_get_output_by_id(_handle, id);
            return ptr == null ? null : new AstalWlOutput(ptr);
        }
        public AstalWlOutput? GetOutputByName(string name)
        {
            fixed (byte* ptr = System.Text.Encoding.UTF8.GetBytes(name + '\0'))
            {
                var result = AstalWlInterop.astal_wl_registry_get_output_by_name(_handle, (sbyte*)ptr);
                return result == null ? null : new AstalWlOutput(result);
            }
        }
        public AstalWlSeat? GetSeatById(uint id)
        {
            var ptr = AstalWlInterop.astal_wl_registry_get_seat_by_id(_handle, id);
            return ptr == null ? null : new AstalWlSeat(ptr);
        }
        public AstalWlSeat? GetSeatByName(string name)
        {
            fixed (byte* ptr = System.Text.Encoding.UTF8.GetBytes(name + '\0'))
            {
                var result = AstalWlInterop.astal_wl_registry_get_seat_by_name(_handle, (sbyte*)ptr);
                return result == null ? null : new AstalWlSeat(result);
            }
        }
    }
}
