using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalRiver;
namespace Aqueous.Bindings.AstalRiver.Services
{
    /// <summary>
    /// Wraps a single River output (monitor) exposed by libastal-river.
    /// </summary>
    public unsafe class AstalRiverOutput
    {
        private readonly _AstalRiverOutput* _handle;
        internal _AstalRiverOutput* Handle => _handle;
        internal AstalRiverOutput(_AstalRiverOutput* handle)
        {
            _handle = handle;
        }

        /// <summary>River's internal numeric id of this output.</summary>
        public uint Id => AstalRiverInterop.astal_river_output_get_id(_handle);

        /// <summary>Name of the output, e.g. "DP-1".</summary>
        public string? Name => Marshal.PtrToStringUTF8((IntPtr)AstalRiverInterop.astal_river_output_get_name(_handle));

        /// <summary>Bitmask of currently focused (visible) tags.</summary>
        public uint FocusedTags => AstalRiverInterop.astal_river_output_get_focused_tags(_handle);

        /// <summary>Bitmask of tags that currently contain at least one view.</summary>
        public uint OccupiedTags => AstalRiverInterop.astal_river_output_get_occupied_tags(_handle);

        /// <summary>Bitmask of tags marked urgent.</summary>
        public uint UrgentTags => AstalRiverInterop.astal_river_output_get_urgent_tags(_handle);

        /// <summary>Name of the current layout on this output.</summary>
        public string? Layout => Marshal.PtrToStringUTF8((IntPtr)AstalRiverInterop.astal_river_output_get_layout(_handle));

        /// <summary>True if this output currently holds keyboard focus.</summary>
        public bool Focused => AstalRiverInterop.astal_river_output_get_focused(_handle) != 0;
    }
}
