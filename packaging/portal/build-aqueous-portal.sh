#!/bin/sh
# Build Aqueous's private, namespaced xdg-desktop-portal-wlr backend.
set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <patched-xdpw-source> <build-dir> <output-root>" >&2
    exit 2
fi

source_dir=$1
build_dir=$2
output_root=$3

if [ -d "$build_dir" ]; then
    meson setup --reconfigure "$build_dir" "$source_dir" \
        --prefix=/usr \
        --sysconfdir=/etc \
        --libexecdir=lib/aqueous \
        --buildtype=release \
        -Dsystemd=disabled \
        -Dman-pages=disabled
else
    meson setup "$build_dir" "$source_dir" \
        --prefix=/usr \
        --sysconfdir=/etc \
        --libexecdir=lib/aqueous \
        --buildtype=release \
        -Dsystemd=disabled \
        -Dman-pages=disabled
fi

meson compile -C "$build_dir"
install -Dm755 "$build_dir/xdg-desktop-portal-aqueous" \
    "$output_root/usr/lib/aqueous/xdg-desktop-portal-aqueous"
