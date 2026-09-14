#!/usr/bin/env bash
# gentoo-install.sh — build and install Aqueous on Gentoo Linux.
#
# Usage:
#   sudo scripts/gentoo-install.sh [all]       deps + build + install (default)
#   sudo scripts/gentoo-install.sh deps        emerge runtime/build deps, fetch zig
#   scripts/gentoo-install.sh build            build compositor + config helper + portal into dist/
#   sudo scripts/gentoo-install.sh install     install into /usr + /etc
#   sudo scripts/gentoo-install.sh uninstall   remove everything this script installed
#
# Env:
#   AQUEOUS_PREFIX       install/uninstall under this prefix instead of /
#                        (dry run without root: AQUEOUS_PREFIX=/tmp/aq $0 install)
#   AQUEOUS_DIST         build output dir (default: <repo>/dist)
#   AQUEOUS_ZIG_VERSION  zig to fetch when PATH has none >= required (0.16.0)
#
# /etc config files (wm.toml, outputs.toml, uwsm/env-aqueous) are never
# clobbered: an existing file is kept and the shipped default is dropped
# next to it as <file>.aqnew.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
dist="${AQUEOUS_DIST:-$root/dist}"
destdir="${AQUEOUS_PREFIX:-}"
component=desktop
if [[ ${1:-} == --core-only ]]; then component=core; shift; fi
zig_required=0.16.0
zig_fetch_version="${AQUEOUS_ZIG_VERSION:-0.16.0}"
xdpw_version=0.8.4
xdpw_sha256=3122966d46ab108f505525bcb2498f9121b446ee8438fbfceb73a7a1fa1ad400
xdpw_url="https://github.com/emersion/xdg-desktop-portal-wlr/archive/refs/tags/v$xdpw_version.tar.gz"

die() { echo "gentoo-install: ERROR: $*" >&2; exit 1; }
say() { echo "gentoo-install: $*"; }

is_root() { [ "$(id -u)" -eq 0 ]; }

zig_ok() {
    command -v zig >/dev/null 2>&1 || return 1
    local zig_ver zig_base
    zig_ver=$(zig version)
    # Strip any -dev.NNN+hash pre-release suffix (see PKGBUILD for why).
    zig_base="${zig_ver%%-*}"
    printf '%s\n%s\n' "$zig_required" "$zig_base" | sort -V -C
}

# --- deps -------------------------------------------------------------------

# PKGBUILD depends+makedepends+checkdepends, mapped to Gentoo atoms.
emerge_atoms=(
    # runtime
    dev-libs/wayland
    dev-libs/wayland-protocols
    x11-libs/libxkbcommon
    x11-libs/libinput
    x11-libs/libevdev
    x11-libs/libdrm
    x11-libs/pixman
    x11-libs/libxcb
    x11-libs/xcb-util
    x11-libs/xcb-util-wm
    x11-libs/libnotify
    x11-libs/libliftoff
    x11-misc/xwayland
    x11-misc/wl-clipboard
    gui-libs/libdecor
    gui-apps/grim
    gui-apps/slurp
    dev-libs/glib
    dev-util/uwsm
    media-libs/mesa
    media-libs/fontconfig
    media-libs/freetype
    media-libs/lcms
    media-libs/vulkan-loader
    dev-libs/vulkan-headers
    sys-apps/systemd
    sys-apps/seatd
    sys-libs/libdisplay-info
    sys-apps/xdg-desktop-portal
    gui-libs/xdg-desktop-portal-gtk
    media-video/pipewire
    media-video/wireplumber
    dev-libs/inih
    # build
    app-text/scdoc
    dev-build/meson
    dev-build/ninja
    dev-build/pkgconf
    media-libs/glslang
    media-libs/shaderc
    sys-apps/hwdata
    dev-vcs/git
    net-misc/curl
    sys-devel/patch
    # build checks
    dev-libs/jq
    dev-lang/python
    app-text/ripgrep
)

if [[ $component == core ]]; then
    core_atoms=()
    for atom in "${emerge_atoms[@]}"; do
        case $atom in
            x11-libs/libnotify|x11-misc/wl-clipboard|gui-apps/grim|gui-apps/slurp|dev-util/uwsm|sys-apps/xdg-desktop-portal|gui-libs/xdg-desktop-portal-gtk|media-video/wireplumber) ;;
            *) core_atoms+=("$atom") ;;
        esac
    done
    emerge_atoms=("${core_atoms[@]}")
else
    emerge_atoms+=(gui-libs/gtk app-admin/sudo)
fi

zig_install() {
    local arch
    case "$(uname -m)" in
        x86_64) arch=x86_64 ;;
        aarch64) arch=aarch64 ;;
        *) die "no prebuilt zig known for $(uname -m); install zig >= $zig_required manually and re-run" ;;
    esac
    local dest="/opt/zig-$zig_fetch_version"
    local zigbin="$dest/zig-linux-$arch-$zig_fetch_version"
    if [ -x "$zigbin/zig" ]; then
        say "zig $zig_fetch_version already present at $zigbin"
    else
        local url="https://ziglang.org/download/$zig_fetch_version/zig-linux-$arch-$zig_fetch_version.tar.xz"
        say "fetching zig $zig_fetch_version from $url"
        local tmp
        tmp=$(mktemp -d)
        if ! { curl -L --fail --silent --show-error "$url" -o "$tmp/zig.tar.xz" \
            && tar -xJf "$tmp/zig.tar.xz" -C "$tmp"; }; then
            rm -rf "$tmp"
            die "zig download/extract failed"
        fi
        mkdir -p "$dest"
        cp -a "$tmp/zig-linux-$arch-$zig_fetch_version/." "$dest/"
        rm -rf "$tmp"
    fi
    ln -sf "$zigbin/zig" /usr/bin/zig
    printf 'export PATH="%s:$PATH"\n' "$zigbin" >/etc/profile.d/aqueous-zig.sh
    say "zig installed at $zigbin (symlinked to /usr/bin/zig)"
}

cmd_deps() {
    is_root || die "deps needs root (emerge)"
    command -v emerge >/dev/null 2>&1 || die "not on Gentoo (emerge not found)"
    say "emerging Aqueous dependencies (runtime + build + checks)..."
    emerge --noremove -1 "${emerge_atoms[@]}"
    if zig_ok; then
        say "zig $(zig version) in PATH — OK"
    else
        zig_install
        zig_ok || die "zig >= $zig_required still not available after install"
        say "zig $(zig version) — OK"
    fi
    if ! command -v noctalia >/dev/null 2>&1; then
        say "note: noctalia shell not found; the Aqueous session works without it."
    fi
}

# --- build ------------------------------------------------------------------

cmd_build() {
    local tool
    for tool in zig cc curl meson ninja patch pkg-config sha256sum scdoc python3 glslc; do
        command -v "$tool" >/dev/null 2>&1 ||
            die "$tool not found (on Gentoo: sudo $0 deps)"
    done
    pkg-config --atleast-version=1.49 wayland-protocols ||
        die "wayland-protocols >= 1.49 not found"
    zig_ok || die "zig >= $zig_required not found (on Gentoo: sudo $0 deps)"
    say "using zig $(zig version)"

    mkdir -p "$dist"
    say "building patched wlroots render hook (this can take a while)..."
    AQUEOUS_WLROOTS_CACHE_DIR="$dist/wlroots-cache" \
        "$root/compositor/scripts/build-wlroots-render-hook.sh"

    say "building Aqueous compositor..."
    # Only clear generated staging metadata, never an existing system installation.
    rm -rf -- "$dist/aqueous-dist/share/aqueous-protocols"
    (
        cd "$root/compositor"
        PKG_CONFIG_PATH="$PWD/.deps/wlroots-render-hook/lib/pkgconfig" \
            zig build -Dcpu=baseline -Doptimize=ReleaseSafe -Dxwayland -Dllvm \
                -Dman-pages=true \
                --prefix "$dist/aqueous-dist" install
    )

    say "building aqueous-config..."
    (
        cd "$root/settingsApplication"
        zig build -Dcpu=baseline -Doptimize=ReleaseSafe \
            --prefix "$dist/aqueous-config-dist" install
    )

    if [[ $component == core ]]; then
        verify_build
        return
    fi
    zig build --build-file "$root/welcome/build.zig" -Dcpu=baseline -Doptimize=ReleaseSafe --prefix "$dist/aqueous-welcome-dist"
    zig build --build-file "$root/packaging/portal/bridge/build.zig" -Dcpu=baseline -Doptimize=ReleaseSafe --prefix "$dist/aqueous-portal-chooser-dist"
    local portal_tmp
    portal_tmp=$(mktemp -d "${TMPDIR:-/tmp}/aqueous-portal.XXXXXX")
    say "building bundled Aqueous portal backend $xdpw_version..."
    curl -L --fail --silent --show-error "$xdpw_url" \
        -o "$portal_tmp/xdpw.tar.gz"
    (
        cd "$portal_tmp"
        printf '%s  %s\n' "$xdpw_sha256" xdpw.tar.gz | sha256sum --check -
    )
    mkdir -p "$portal_tmp/source"
    tar -xzf "$portal_tmp/xdpw.tar.gz" --strip-components=1 \
        -C "$portal_tmp/source"
    patch --fuzz=0 -d "$portal_tmp/source" -Np1 < \
        "$root/packaging/portal/0001-rename-backend-for-aqueous.patch"
    sh "$root/packaging/portal/build-aqueous-portal.sh" \
        "$portal_tmp/source" \
        "$portal_tmp/build" \
        "$dist/aqueous-portal-dist"
    install -Dm644 "$portal_tmp/source/LICENSE" \
        "$dist/aqueous-portal-dist/usr/share/licenses/aqueous/xdg-desktop-portal-wlr/LICENSE"
    rm -rf -- "$portal_tmp"

    verify_build
}

verify_build() {
    say "verifying build outputs..."
    local required=(
        bin/aqueous
        bin/aqueousctl
        lib/aqueous/libwlroots-0.20.so
        share/man/man1/aqueousctl.1
        share/aqueous-protocols/stable/aqueous-window-info-v1.xml
        share/aqueous-protocols/stable/aqueous-window-management-v1.xml
        share/aqueous-protocols/stable/aqueous-input-management-v1.xml
        share/aqueous-protocols/stable/aqueous-xkb-bindings-v1.xml
        share/aqueous-protocols/stable/aqueous-xkb-config-v1.xml
        share/aqueous-protocols/stable/aqueous-libinput-config-v1.xml
        share/aqueous-protocols/stable/aqueous-layer-shell-v1.xml
    )
    local path
    for path in "${required[@]}"; do
        [ -e "$dist/aqueous-dist/$path" ] || die "build output missing: $path"
    done
    cmp -s "$dist/aqueous-dist/lib/aqueous/libwlroots-0.20.so" \
        "$root/compositor/.deps/wlroots-render-hook/lib/libwlroots-0.20.so" ||
        die "installed libwlroots-0.20.so differs from the built one"
    readelf -d "$dist/aqueous-dist/bin/aqueous" |
        grep -F '$ORIGIN/../lib/aqueous' >/dev/null ||
        die "compositor rpath does not point at \$ORIGIN/../lib/aqueous"
    if readelf -d "$dist/aqueous-dist/bin/aqueous" | grep -qi scenefx; then
        die "compositor still links SceneFX"
    fi
    [ -x "$dist/aqueous-config-dist/bin/aqueous-config" ] ||
        die "build output missing: aqueous-config-dist/bin/aqueous-config"
    if [[ $component == desktop ]]; then
    [ -x "$dist/aqueous-portal-dist/usr/lib/aqueous/xdg-desktop-portal-aqueous" ] ||
        die "build output missing: aqueous-portal-dist/usr/lib/aqueous/xdg-desktop-portal-aqueous"
    fi
    zig build --build-file "$root/settingsApplication/build.zig" test test-driver -Dmodel-only=true --prefix "$dist/aqueous-config-tests"
    "$root/settingsApplication/tests/test-backend.sh" "$dist/aqueous-config-tests/bin/aqueous-backend-test"
    AQUEOUSCTL_BINARY="$dist/aqueous-dist/bin/aqueousctl" AQUEOUS_CONFIG_BINARY="$dist/aqueous-config-dist/bin/aqueous-config" "$root/settingsApplication/tests/test-packaging.sh"
    if [[ $component == desktop ]]; then
    "$root/packaging/tests/test-portal-packaging.sh" \
        "$dist/aqueous-portal-dist/usr/lib/aqueous/xdg-desktop-portal-aqueous"
    fi
    say "build verified"
}

# --- install ----------------------------------------------------------------

# $1 = destination path (under $destdir), $2 = source. Existing files are
# never clobbered; the shipped default lands as $1.aqnew instead.
install_etc() {
    local dest=$1 src=$2
    if [ -e "$dest" ]; then
        if ! cmp -s "$dest" "$src"; then
            install -m644 "$src" "$dest.aqnew"
            say "kept existing $dest; shipped default written to $dest.aqnew"
        fi
        return 0
    fi
    install -Dm644 "$src" "$dest"
}

# "type<TAB>path" listing (F = file/symlink, D = directory) of a tree,
# whole-line C-collated so comm(1) accepts it. Within a section the sort is
# by path, so parent directories always precede their children (uninstall
# relies on that to rmdir deepest-first).
tree_list() {
    [ -d "$1" ] || return 0
    local p
    while IFS= read -r -d '' p; do
        if [ -d "$p" ] && [ ! -L "$p" ]; then
            printf 'D\t%s\n' "$p"
        else
            printf 'F\t%s\n' "$p"
        fi
    done < <(find "$1" -mindepth 1 \( -type f -o -type l -o -type d \) -print0 2>/dev/null) |
        LC_ALL=C sort
}

install_into() {
    local D=$1 stage part file relative
    stage=$(mktemp -d "${TMPDIR:-/tmp}/aqueous-components.XXXXXX")
    local parts=(core)
    if [[ $component == desktop ]]; then
        parts+=(session welcome portal integration-dms integration-noctalia integration-pearl)
    fi
    for part in "${parts[@]}"; do
        AQUEOUS_COMPOSITOR_DIST="$dist/aqueous-dist" \
        AQUEOUS_CONFIG_BINARY="$dist/aqueous-config-dist/bin/aqueous-config" \
        AQUEOUS_WELCOME_BINARY="$dist/aqueous-welcome-dist/bin/aqueous-welcome" \
        AQUEOUS_PORTAL_BINARY="$dist/aqueous-portal-dist/usr/lib/aqueous/xdg-desktop-portal-aqueous" \
        AQUEOUS_PORTAL_LICENSE="$dist/aqueous-portal-dist/usr/share/licenses/aqueous/xdg-desktop-portal-wlr/LICENSE" \
        AQUEOUS_PORTAL_CHOOSER_BINARY="$dist/aqueous-portal-chooser-dist/bin/aqueous-dms-portal-chooser" \
            DESTDIR="$stage/$part" PREFIX=/usr "$root/packaging/stage-component.sh" "$part"
    done
    # Staging is complete before any installed files are touched.
    : > "$stage/manifest"
    for part in "${parts[@]}"; do
        while IFS= read -r -d '' file; do
            relative=${file#"$stage/$part/"}
            printf 'F\t%s\n' "$D/$relative" >> "$stage/manifest"
            if [[ $relative == etc/* && ! -L $file ]]; then
                install_etc "$D/$relative" "$file"
                install -Dm644 "$file" "$D/var/lib/aqueous/defaults/$relative"
                printf 'F\t%s\n' "$D/var/lib/aqueous/defaults/$relative" >> "$stage/manifest"
                if [[ -f $D/$relative.aqnew ]]; then
                    printf 'F\t%s\n' "$D/$relative.aqnew" >> "$stage/manifest"
                fi
            else
                install -d "${D}/${relative%/*}"
                cp -aT -- "$file" "$D/$relative"
            fi
        done < <(find "$stage/$part" \( -type f -o -type l \) -print0)
    done
    local manifest="$D/var/lib/aqueous/manifest"
    install -d "${manifest%/*}"
    if [[ -f $manifest ]]; then cat "$manifest" >> "$stage/manifest"; fi
    LC_ALL=C sort -u "$stage/manifest" > "$manifest"
    rm -rf -- "$stage"
}

cmd_install() {
    [ -d "$dist/aqueous-dist" ] || die "compositor not built (run: $0 build)"
    [ -d "$dist/aqueous-config-dist" ] || die "configuration helper not built (run: $0 build)"
    if [[ $component == desktop ]]; then
        [ -d "$dist/aqueous-portal-dist" ] || die "portal backend not built (run: $0 build)"
    fi
    if [ -z "$destdir" ] && ! is_root; then
        die "install needs root (dry run: AQUEOUS_PREFIX=/tmp/aq $0 install)"
    fi

    say "installing into prefix ${destdir:-/}"
    # Record known payload paths even for a live-root install. Never scan / or
    # infer ownership from unrelated filesystem changes during installation.
    install_into "$destdir"
    local mf="$destdir/var/lib/aqueous/manifest"

    say "installed $(grep -c "^F" "$mf") files into ${destdir:-/}"
    if [[ $component == core ]]; then
        say "Shell-independent core installed. No session was configured."
    else
        print_install_notice
    fi
}

print_install_notice() {
    cat <<'EOF'

Aqueous is installed.

    Select "Aqueous" from your display manager's Wayland session list.
    The session runs through uwsm; no user unit needs enabling.

    Per-user config: ~/.config/aqueous/ (wm.toml and the outputs.toml
    template are copied there on first login only when missing).

    Useful commands:
        aqueous-config snapshot --shell none
        aqueousctl windows
        aqueousctl outputs
        aqueousctl layout --output <name> --json

    Session log: $XDG_RUNTIME_DIR/aqueous-wm.log

    Screen recording and sharing use the packaged Aqueous portal backend;
    xdg-desktop-portal-wlr does not need to be installed separately.

    If you were logged in during the install, log out and back in.
    Without logging out:  systemctl --user daemon-reload
EOF
}

print_remove_notice() {
    cat <<'EOF'

Aqueous removed.

    Per-user configuration, cache, and state were retained:
        ~/.config/aqueous
        ~/.cache/aqueous
        ~/.local/state/aqueous
EOF
}

# Shipped source for a known /etc config file, empty for anything else.
etc_source() {
    local relative=${1#"$destdir/"}
    local original="$destdir/var/lib/aqueous/defaults/$relative"
    [[ -f $original ]] || return 1
    printf '%s\n' "$original"
}

cmd_uninstall() {
    local mf="$destdir/var/lib/aqueous/manifest"
    [ -f "$mf" ] || die "no install manifest at $mf — nothing installed by this script"
    if [ -z "$destdir" ] && ! is_root; then
        die "uninstall needs root (dry run: AQUEOUS_PREFIX=/tmp/aq $0 uninstall)"
    fi

    local kind path src
    while IFS=$'\t' read -r kind path; do
        [ -n "$path" ] || continue
        if [ "$kind" = F ]; then
            case "$path" in
                "$destdir/etc/"*)
                    # CONFIG_PROTECT-like: /etc files the user modified are
                    # kept; pristine copies and our *.aqnew drops are removed.
                    case "$path" in *.aqnew) rm -f -- "$path"; continue ;; esac
                    if src=$(etc_source "$path") && [ -n "$src" ] &&
                        ! cmp -s "$path" "$src"; then
                        say "kept modified config: $path"
                        continue
                    fi
                    ;;
            esac
            rm -f -- "$path"
        fi
    done <"$mf"

    # D entries are parents-before-children (sorted), so remove in reverse.
    local dirs=()
    while IFS= read -r path; do
        [ -n "$path" ] && dirs+=("$path")
    done < <(awk -F'\t' '$1 == "D" { print $2 }' "$mf")
    local i
    for ((i = ${#dirs[@]} - 1; i >= 0; i--)); do
        rmdir -- "${dirs[$i]}" 2>/dev/null || true
    done

    local state_dir="${mf%/*}"
    local var_lib="${state_dir%/*}"
    rm -f -- "$mf"
    rmdir -- "$state_dir" 2>/dev/null || true
    rmdir -- "$var_lib" 2>/dev/null || true
    rmdir -- "${var_lib%/*}" 2>/dev/null || true

    say "uninstalled Aqueous from prefix ${destdir:-/}"
    print_remove_notice
}

# --- main -------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: sudo $0 [--core-only] [all|deps|build|install|uninstall]

  all        deps + build + install (default)
  deps       emerge runtime/build deps, fetch zig if missing
  build      build compositor + config helper + portal backend into $dist
  install    install into /usr + /etc (root; AQUEOUS_PREFIX for dry run)
  uninstall  remove everything this script installed
EOF
    exit 2
}

case "${1:-all}" in
    all)
        cmd_deps
        cmd_build
        cmd_install
        ;;
    deps) cmd_deps ;;
    build) cmd_build ;;
    install) cmd_install ;;
    uninstall) cmd_uninstall ;;
    *) usage ;;
esac
