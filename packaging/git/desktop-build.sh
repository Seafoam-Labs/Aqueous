#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
case ${2:-} in git) channel=$2;; *) echo 'Expected build|check|package git [COMPONENT]' >&2; exit 2;; esac
instance=aqueous-$channel
: "${srcdir:?}" "${pkgver:?}"
welcome=$srcdir/$instance-welcome-dist
portal=$srcdir/$instance-portal-dist
portal_source=$srcdir/$instance-portal-source
export ZIG_GLOBAL_CACHE_DIR=$srcdir/$instance-desktop-zig-global
source "$root/packaging/cpu-target.sh"
case ${1:-} in
build)
    zig build --build-file "$root/welcome/build.zig" -Dcpu="$AQUEOUS_ZIG_CPU" -Doptimize=ReleaseSafe \
        -Dinstance-name="$instance" --prefix "$welcome"
    # Copy the pinned source; never mutate another variant's prepared tree.
    [[ ! -e $portal_source ]] || rm -rf -- "$portal_source"
    cp -a "$srcdir/xdg-desktop-portal-wlr-0.8.4" "$portal_source"
    patch --fuzz=0 -d "$portal_source" -Np1 < "$root/packaging/portal/0001-rename-backend-for-aqueous.patch"
    sed -i "s/xdg-desktop-portal-aqueous/xdg-desktop-portal-$instance/g" "$portal_source/meson.build" "$portal_source/src/core/main.c" "$portal_source/src/core/config.c"
    sed -i "s/org.freedesktop.impl.portal.desktop.aqueous/org.freedesktop.impl.portal.desktop.${instance//-/_}/g" "$portal_source/src/core/main.c"
    args=(); [[ ! -f $srcdir/$instance-portal-build/build.ninja ]] || args+=(--wipe)
    meson setup "${args[@]}" "$srcdir/$instance-portal-build" "$portal_source" \
        --prefix=/usr --sysconfdir=/etc --libexecdir="lib/$instance" --buildtype=release \
        -Dsystemd=disabled -Dman-pages=disabled
    meson compile -C "$srcdir/$instance-portal-build"
    install -Dm755 "$srcdir/$instance-portal-build/xdg-desktop-portal-$instance" "$portal/xdg-desktop-portal-$instance"
    jq -n --arg instance "$instance" '{schema:1,instance:$instance}' > "$portal/build-instance.json"
    ;;
check)
    zig build --build-file "$root/welcome/build.zig" test -Dcpu="$AQUEOUS_ZIG_CPU" -Doptimize=ReleaseSafe
    bash "$root/packaging/tests/test-git-desktop.sh" "$welcome" "$portal" "$channel" "$portal_source/LICENSE"
    ;;
package)
    AQUEOUS_WELCOME_DIST="$welcome" AQUEOUS_PORTAL_DIST="$portal" AQUEOUS_PORTAL_LICENSE="$portal_source/LICENSE" \
        DESTDIR="${pkgdir:?}" bash "$root/packaging/git/desktop-stage.sh" "$channel" "${3:?}"
    ;;
*) exit 2;;
esac
