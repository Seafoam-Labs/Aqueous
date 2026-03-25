using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalMpris;
namespace Aqueous.Bindings.AstalMpris.Services
{
    public unsafe class AstalMprisMpris
    {
        private _AstalMprisMpris* _handle;
        internal _AstalMprisMpris* Handle => _handle;
        internal AstalMprisMpris(_AstalMprisMpris* handle)
        {
            _handle = handle;
        }
        public static AstalMprisMpris? GetDefault()
        {
            var ptr = AstalMprisInterop.astal_mpris_mpris_get_default();
            return ptr == null ? null : new AstalMprisMpris(ptr);
        }
    }
}
