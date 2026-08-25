#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
version=0.20.2
archive_sha256=972c7ac44b17828f4702bfae7cd8347346a3fb5b2c1076cfa2c3fcedac5ec343
archive_url="https://gitlab.freedesktop.org/wlroots/wlroots/-/archive/$version/wlroots-$version.tar.gz"
patch_files=(
    "$here/patches/wlroots/0001-aqueous-vulkan-render-hook.patch"
    "$here/patches/wlroots/0002-fix-hdr-min-luminance.patch"
    "$here/patches/wlroots/0003-color-management-v1-srgb-compat.patch"
    "$here/patches/wlroots/0004-scene-sdr-white-level.patch"
    "$here/patches/wlroots/0005-drm-expose-edid-hdr-static-metadata.patch"
    "$here/patches/wlroots/0006-color-management-v1-windows-hdr.patch"
    "$here/patches/wlroots/0007-scene-precise-position.patch"
    "$here/patches/wlroots/0008-xwayland-native-scaling.patch"
)
prefix=${1:-"$here/.deps/wlroots-render-hook"}
cache_dir=${AQUEOUS_WLROOTS_CACHE_DIR:-"$here/.deps/downloads"}
archive="$cache_dir/wlroots-$version.tar.gz"

die() { echo "FAIL: $*" >&2; exit 1; }
for tool in cc curl meson ninja patch pkg-config sha256sum tar; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
pkg-config --atleast-version=1.49 wayland-protocols ||
    die "wayland-protocols 1.49 or newer is required"
for patch_file in "${patch_files[@]}"; do
    [ -r "$patch_file" ] || die "missing wlroots patch: $patch_file"
done

mkdir -p "$cache_dir"
if [ ! -f "$archive" ]; then
    curl -L --fail --silent --show-error "$archive_url" -o "$archive.tmp"
    mv "$archive.tmp" "$archive"
fi
printf '%s  %s\n' "$archive_sha256" "$archive" | sha256sum -c - >/dev/null ||
    die "wlroots source archive checksum mismatch"

build_root=$(mktemp -d /tmp/aqueous-wlroots-render-hook.XXXXXX)
cleanup() { rm -rf "$build_root"; }
trap cleanup EXIT
source_dir="$build_root/source"
build_dir="$build_root/build"
mkdir -p "$source_dir"
tar -xzf "$archive" --strip-components=1 -C "$source_dir"
for patch_file in "${patch_files[@]}"; do
    patch -d "$source_dir" -p1 <"$patch_file"
done
scene_source="$source_dir/types/scene/wlr_scene.c"
grep -Fq 'scene_output_damage_internal(scene_output, &damage, false);' \
    "$scene_source" ||
    die "patched wlroots does not separate output-only and scene damage"
grep -Fq 'render_pass, &scene_output->pending_effect_damage,' \
    "$scene_source" ||
    die "patched wlroots does not pass full scene damage to the render hook"
color_manager_source="$source_dir/types/wlr_color_management_v1.c"
grep -Fq '#define COLOR_MANAGEMENT_V1_VERSION 3' "$color_manager_source" ||
    die "patched wlroots does not expose color-management-v1 version 3"
grep -Fq 'WP_COLOR_MANAGER_V1_FEATURE_WINDOWS_BT2100' "$color_manager_source" ||
    die "patched wlroots does not advertise Windows BT.2100"
grep -Fq 'WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ ? target_max_lum : 0' \
    "$color_manager_source" ||
    die "patched wlroots does not preserve Proton target/reference HDR headroom"
grep -Fq 'wp_color_management_output_v1_send_image_description_changed' \
    "$color_manager_source" ||
    die "patched wlroots does not notify clients about output color changes"
history_line=$(
    grep -nF 'wlr_damage_ring_add(&scene_output->damage_ring,' \
        "$scene_source" | tail -1 | cut -d: -f1
)
rotate_line=$(
    grep -nF 'wlr_damage_ring_rotate_buffer(&scene_output->damage_ring, buffer,' \
        "$scene_source" | tail -1 | cut -d: -f1
)
[ -n "$history_line" ] && [ -n "$rotate_line" ] &&
    [ "$history_line" -lt "$rotate_line" ] ||
    die "expanded effect damage is not recorded before buffer-history rotation"

meson setup "$build_dir" "$source_dir" \
    --prefix="$prefix" \
    --libdir=lib \
    -Dexamples=false \
    -Dxwayland=enabled \
    -Drenderers=vulkan \
    -Dbackends=drm,libinput,x11 \
    -Dallocators=gbm \
    -Dsession=enabled \
    -Dcolor-management=enabled
meson compile -C "$build_dir"
meson install -C "$build_dir"

library="$prefix/lib/libwlroots-0.20.so"
[ -f "$library" ] || die "patched wlroots library was not installed"
for symbol in \
    wlr_scene_output_set_buffer_render_hook \
    wlr_scene_output_set_buffer_needs_composition \
    wlr_scene_output_set_rect_render_hook \
    wlr_scene_output_set_render_hooks \
    wlr_scene_node_set_position_f64 \
    wlr_scene_node_coords_f64 \
    wlr_scene_surface_set_destination_scale \
    wlr_scene_surface_get_destination_scale \
    wlr_scene_surface_map_point_to_destination \
    wlr_output_set_client_projection_handler \
    wlr_xdg_output_manager_v1_update \
    wlr_scene_buffer_set_force_blend \
    wlr_scene_rect_set_force_blend \
    wlr_vk_renderer_enable_offscreen \
    wlr_vk_render_pass_run_offscreen \
    wlr_vk_render_pass_add_completion \
    wlr_vk_render_pass_set_texture_hook \
    wlr_vk_render_pass_get_attribs \
    wlr_output_get_edid_hdr_static_metadata \
    wlr_color_manager_v1_set_windows_hdr_features \
    wlr_color_manager_v1_encode_luminances \
    wlr_surface_has_windows_hdr_image_description \
    wlr_surface_has_windows_scrgb_image_description \
    wlr_backend_is_x11 \
    wlr_xwayland_create; do
    nm -D --defined-only "$library" | grep " $symbol$" >/dev/null ||
        die "patched wlroots is missing $symbol"
done

probe="$build_root/scene-precise-position"
cc "$here/scripts/fixtures/wlroots-precise-position.c" \
    -o "$probe" \
    $(PKG_CONFIG_PATH="$prefix/lib/pkgconfig" pkg-config --cflags --libs wlroots-0.20)
LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$probe" ||
    die "patched wlroots did not preserve precise scene coordinates"

echo "patched wlroots $version installed at $prefix"
echo "export PKG_CONFIG_PATH=$prefix/lib/pkgconfig"
echo "export LD_LIBRARY_PATH=$prefix/lib"
