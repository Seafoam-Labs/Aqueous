using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalGreet;
namespace Aqueous.Bindings.AstalGreet.Services
{
    public unsafe class AstalGreetSuccess
    {
        private _AstalGreetSuccess* _handle;
        internal _AstalGreetSuccess* Handle => _handle;
        internal AstalGreetSuccess(_AstalGreetSuccess* handle)
        {
            _handle = handle;
        }
    }
}
