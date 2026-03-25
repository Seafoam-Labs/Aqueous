using System;
using System.Runtime.InteropServices;
namespace Aqueous.Bindings.AstalCava
{
    public static unsafe partial class AstalCavaInterop
    {
        private const string LibName = "libastal-cava.so";

        // AstalCavaInput enum
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_cava_input_get_type();

        // AstalCavaCava
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_cava_cava_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalCavaCava *")]
        public static partial _AstalCavaCava* astal_cava_cava_get_default();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalCavaCava *")]
        public static partial _AstalCavaCava* astal_cava_get_default();

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_cava_cava_get_active([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self);

        [LibraryImport(LibName)]
        public static partial void astal_cava_cava_set_active([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self, [NativeTypeName("gboolean")] int active);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GArray *")]
        public static partial _GArray* astal_cava_cava_get_values([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_cava_cava_get_bars([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self);

        [LibraryImport(LibName)]
        public static partial void astal_cava_cava_set_bars([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self, [NativeTypeName("gint")] int bars);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_cava_cava_get_autosens([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self);

        [LibraryImport(LibName)]
        public static partial void astal_cava_cava_set_autosens([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self, [NativeTypeName("gboolean")] int autosens);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_cava_cava_get_stereo([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self);

        [LibraryImport(LibName)]
        public static partial void astal_cava_cava_set_stereo([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self, [NativeTypeName("gboolean")] int stereo);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_cava_cava_get_noise_reduction([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self);

        [LibraryImport(LibName)]
        public static partial void astal_cava_cava_set_noise_reduction([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self, [NativeTypeName("gdouble")] double noise);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_cava_cava_get_framerate([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self);

        [LibraryImport(LibName)]
        public static partial void astal_cava_cava_set_framerate([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self, [NativeTypeName("gint")] int framerate);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalCavaInput")]
        public static partial int astal_cava_cava_get_input([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self);

        [LibraryImport(LibName)]
        public static partial void astal_cava_cava_set_input([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self, [NativeTypeName("AstalCavaInput")] int input);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_cava_cava_get_source([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self);

        [LibraryImport(LibName)]
        public static partial void astal_cava_cava_set_source([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self, [NativeTypeName("const gchar *")] sbyte* source);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_cava_cava_get_channels([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self);

        [LibraryImport(LibName)]
        public static partial void astal_cava_cava_set_channels([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self, [NativeTypeName("gint")] int channels);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_cava_cava_get_low_cutoff([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self);

        [LibraryImport(LibName)]
        public static partial void astal_cava_cava_set_low_cutoff([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self, [NativeTypeName("gint")] int low_cutoff);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_cava_cava_get_high_cutoff([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self);

        [LibraryImport(LibName)]
        public static partial void astal_cava_cava_set_high_cutoff([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self, [NativeTypeName("gint")] int high_cutoff);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_cava_cava_get_samplerate([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self);

        [LibraryImport(LibName)]
        public static partial void astal_cava_cava_set_samplerate([NativeTypeName("AstalCavaCava *")] _AstalCavaCava* self, [NativeTypeName("gint")] int samplerate);
    }
}
