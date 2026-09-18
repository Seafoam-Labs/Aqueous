#!/usr/bin/env bash
# Shared makepkg implementation; metadata stays in each standalone PKGBUILD.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
case ${2:-} in git) channel=$2;; *) echo 'Usage: build.sh build|check|package git' >&2; exit 2;; esac
instance=aqueous-$channel
: "${srcdir:?}" "${pkgver:?}"
compositor=$srcdir/$instance-dist
helper=$srcdir/$instance-config-dist
export ZIG_GLOBAL_CACHE_DIR=$srcdir/$instance-zig-global
source "$root/packaging/cpu-target.sh"
case ${1:-} in
build)
    zig build --build-file "$root/settingsApplication/build.zig" \
        -Dcpu="$AQUEOUS_ZIG_CPU" -Doptimize=ReleaseSafe -Dinstance-name="$instance" --prefix "$helper"
    AQUEOUS_WLROOTS_CACHE_DIR="$srcdir" "$root/compositor/scripts/build-wlroots-render-hook.sh"
    export PKG_CONFIG_PATH="$root/compositor/.deps/wlroots-render-hook/lib/pkgconfig"
    zig build --build-file "$root/compositor/build.zig" \
        -Dcpu="$AQUEOUS_ZIG_CPU" -Doptimize=ReleaseSafe -Dxwayland -Dllvm -Dman-pages=true \
        -Dinstance-name="$instance" -Dversion-string="$pkgver ($instance)" --prefix "$compositor"
    ;;
check)
    zig build --build-file "$root/settingsApplication/build.zig" test -Dmodel-only=true -Dcpu="$AQUEOUS_ZIG_CPU" -Doptimize=ReleaseSafe
    bash "$root/packaging/tests/test-git-packages.sh" "$compositor" "$helper" "$channel"
    ;;
package)
    AQUEOUS_COMPOSITOR_DIST="$compositor" AQUEOUS_CONFIG_DIST="$helper" \
        DESTDIR="${pkgdir:?}" PREFIX=/usr bash "$root/packaging/git/stage.sh" "$channel"
    ;;
*) exit 2;;
esac
