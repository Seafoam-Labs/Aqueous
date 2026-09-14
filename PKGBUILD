# Maintainer: Zoey Bauer <zoey.erin.bauer@gmail.com>
# Maintainer: Caroline Snyder <hirpeng@gmail.com>
pkgname=(aqueous-core aqueous-session aqueous-welcome xdg-desktop-portal-aqueous
         aqueous-integration-dms aqueous-integration-noctalia aqueous-integration-pearl
         aqueous-shell-dms aqueous-shell-noctalia aqueous-shell-pearl aqueous)
pkgbase=aqueous
pkgver=0.7.0
pkgrel=2
# Keep tested binary/library bytes and component manifests stable.
options=('!strip' '!debug' '!zipman')
pkgdesc="Aqueous single-process Wayland compositor"
arch=('x86_64' 'aarch64')
url="https://github.com/Seafoam-Labs/Aqueous"
license=('GPL3' 'MIT' 'custom:PX')
makedepends=('jq' 'gtk4' 'freetype2' 'wayland' 'libxkbcommon' 'libinput' 'pixman' 'libpng' 'libdrm' 'libevdev' 'libdecor' 'libinih' 'pipewire' 'mesa' 'systemd-libs' 'seatd' 'libdisplay-info' 'libliftoff' 'lcms2' 'vulkan-icd-loader' 'libxcb' 'xcb-util-errors' 'xcb-util-wm' 'xcb-util-renderutil' 'python' 'shaderc' 'clang' 'lld' 'llvm'
             'git' 'curl' 'patch' 'scdoc' 'wayland-protocols>=1.49' 'pkgconf'
             'meson' 'ninja' 'glslang' 'vulkan-headers' 'hwdata' 'zig>=0.16')
# Helper integration checks exercise org.gnome.desktop.interface via gsettings.
checkdepends=('libarchive' 'jq' 'python' 'ripgrep' 'qt6-declarative' 'gsettings-desktop-schemas')
source=(
    "aqueous::git+${url}.git#tag=v${pkgver}"
    "wlroots-0.20.2.tar.gz::https://gitlab.freedesktop.org/wlroots/wlroots/-/archive/0.20.2/wlroots-0.20.2.tar.gz"
    "xdg-desktop-portal-wlr-0.8.4.tar.gz::https://github.com/emersion/xdg-desktop-portal-wlr/archive/refs/tags/v0.8.4.tar.gz"
)
sha256sums=(
    'SKIP'
    '972c7ac44b17828f4702bfae7cd8347346a3fb5b2c1076cfa2c3fcedac5ec343'
    '3122966d46ab108f505525bcb2498f9121b446ee8438fbfceb73a7a1fa1ad400'
)

prepare() {
    patch --fuzz=0 -d "$srcdir/xdg-desktop-portal-wlr-0.8.4" -Np1 \
        -i "$srcdir/aqueous/packaging/portal/0001-rename-backend-for-aqueous.patch"
}

build() {
    ZIG_GLOBAL_CACHE_DIR="$srcdir/aqueous-welcome-zig-global" \
    ZIG_LOCAL_CACHE_DIR="$srcdir/aqueous-welcome-zig-local" \
        zig build --build-file "$srcdir/aqueous/welcome/build.zig" \
        -Dcpu=baseline -Doptimize=ReleaseSafe --prefix "$srcdir/aqueous-welcome-dist"

    # Canonical configuration helper; Pearl supplies the settings UI.
    ZIG_GLOBAL_CACHE_DIR="$srcdir/aqueous-config-zig-global" \
    ZIG_LOCAL_CACHE_DIR="$srcdir/aqueous-config-zig-local" \
        zig build --build-file "$srcdir/aqueous/settingsApplication/build.zig" \
        -Dcpu=baseline -Doptimize=ReleaseSafe --prefix "$srcdir/aqueous-config-dist"

    # Verify zig is new enough (the Aqueous compositor requires >= 0.16.0).
    # We enforce this here instead of via a pacman version constraint because
    # the repo `zig` package is currently 0.15.x and Zig 0.16 is only available
    # via `zig-master-bin` (AUR), which provides unversioned `zig`.
    if ! command -v zig >/dev/null 2>&1; then
        error "zig not found. Install zig-master-bin from the AUR (or another zig >= 0.16.0)."
        return 1
    fi
    local zig_ver zig_base
    zig_ver=$(zig version)
    # Strip any -dev.NNN+hash pre-release suffix so we compare the numeric base
    # version with sort -V (which has inconsistent semantics around bare `-`).
    zig_base="${zig_ver%%-*}"
    if ! printf '0.16.0\n%s\n' "$zig_base" | sort -V -C; then
        error "Zig >= 0.16.0 required, found $zig_ver. Install zig-master-bin from the AUR."
        return 1
    fi
    msg2 "Using zig $zig_ver"

    cd "$srcdir/aqueous"

    # Build the Aqueous compositor/policy executable and inspection client.
    msg2 "Building Aqueous compositor..."
    cd "$srcdir/aqueous/compositor"
    # Recreate generated protocol metadata so incremental builds cannot ship retired names.
    rm -rf -- "$srcdir/aqueous-dist/share/aqueous-protocols"
    # -Dllvm forces the LLVM backend + LLD linker. Zig 0.16.0's self-hosted
    # ELF linker can't handle R_X86_64_PC64 in .sframe emitted by gcc >= 16.
    # Keep the manuals deterministic in clean chroots. In-tree builds make
    # them optional when scdoc is absent, but packages must always document
    # both installed executables, including aqueousctl.
    AQUEOUS_WLROOTS_CACHE_DIR="$srcdir" \
        scripts/build-wlroots-render-hook.sh
    PKG_CONFIG_PATH="$PWD/.deps/wlroots-render-hook/lib/pkgconfig" \
    zig build -Dcpu=baseline -Doptimize=ReleaseSafe -Dxwayland -Dllvm \
        -Dman-pages=true -Dversion-string="$pkgver" \
        --prefix "$srcdir/aqueous-dist" install

    msg2 "Building bundled xdg-desktop-portal-aqueous 0.8.4..."
    sh "$srcdir/aqueous/packaging/portal/build-aqueous-portal.sh" \
        "$srcdir/xdg-desktop-portal-wlr-0.8.4" \
        "$srcdir/aqueous-portal-build" \
        "$srcdir/aqueous-portal-dist"
    msg2 "Building DMS portal chooser..."
    ZIG_GLOBAL_CACHE_DIR="$srcdir/aqueous-plugin-zig-global" \
    ZIG_LOCAL_CACHE_DIR="$srcdir/aqueous-portal-chooser-cache" \
        zig build --build-file "$srcdir/aqueous/packaging/portal/bridge/build.zig" \
        -Dcpu=baseline -Doptimize=ReleaseSafe --prefix "$srcdir/aqueous-portal-chooser-dist"

}

check() {
    ZIG_GLOBAL_CACHE_DIR="$srcdir/aqueous-config-zig-global" \
    ZIG_LOCAL_CACHE_DIR="$srcdir/aqueous-config-zig-local" \
        zig build --build-file "$srcdir/aqueous/settingsApplication/build.zig" test test-driver -Dmodel-only=true --prefix "$srcdir/aqueous-config-tests"
    AQUEOUS_CONFIG_BINARY="$srcdir/aqueous-config-dist/bin/aqueous-config" \
    AQUEOUSCTL_BINARY="$srcdir/aqueous-dist/bin/aqueousctl" \
        "$srcdir/aqueous/settingsApplication/tests/test-packaging.sh"
    "$srcdir/aqueous/settingsApplication/tests/test-backend.sh" "$srcdir/aqueous-config-tests/bin/aqueous-backend-test"

    python3 "$srcdir/aqueous/packaging/tests/test-dms-git-packaging.py"
    bash "$srcdir/aqueous/packaging/tests/test-components.sh"
    # aqueousctl and its protocol/manual are one feature: reject a partial
    # install tree before package() copies it into the package image.
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
        if [[ ! -e "$srcdir/aqueous-dist/$path" ]]; then
            error "build output is missing required file: $path"
            return 1
        fi
    done
    if [[ ! -x "$srcdir/aqueous-portal-dist/usr/lib/aqueous/xdg-desktop-portal-aqueous" ]]; then
        error "build output is missing required portal backend"
        return 1
    fi
    cmp "$srcdir/aqueous-dist/lib/aqueous/libwlroots-0.20.so" \
        "$srcdir/aqueous/compositor/.deps/wlroots-render-hook/lib/libwlroots-0.20.so"
    readelf -d "$srcdir/aqueous-dist/bin/aqueous" |
        grep -F '$ORIGIN/../lib/aqueous' >/dev/null
    if readelf -d "$srcdir/aqueous-dist/bin/aqueous" |
        grep -i 'scenefx' >/dev/null; then
        error "compositor still links SceneFX"
        return 1
    fi

    "$srcdir/aqueous/packaging/tests/test-portal-chooser.sh" \
        "$srcdir/aqueous-portal-chooser-dist/bin/aqueous-dms-portal-chooser"
    "$srcdir/aqueous/packaging/tests/test-portal-packaging.sh" \
        "$srcdir/aqueous-portal-dist/usr/lib/aqueous/xdg-desktop-portal-aqueous"
}

_stage_component() {
    AQUEOUS_COMPOSITOR_DIST="$srcdir/aqueous-dist" \
    AQUEOUS_CONFIG_BINARY="$srcdir/aqueous-config-dist/bin/aqueous-config" \
    AQUEOUS_WELCOME_BINARY="$srcdir/aqueous-welcome-dist/bin/aqueous-welcome" \
    AQUEOUS_PORTAL_BINARY="$srcdir/aqueous-portal-dist/usr/lib/aqueous/xdg-desktop-portal-aqueous" \
    AQUEOUS_PORTAL_LICENSE="$srcdir/xdg-desktop-portal-wlr-0.8.4/LICENSE" \
    AQUEOUS_PORTAL_CHOOSER_BINARY="$srcdir/aqueous-portal-chooser-dist/bin/aqueous-dms-portal-chooser" \
        DESTDIR="$pkgdir" PREFIX=/usr "$srcdir/aqueous/packaging/stage-component.sh" "$1"
}

package_aqueous-core() {
    pkgdesc="Aqueous core"
    depends=("freetype2" "wayland" "libxkbcommon" "libinput" "pixman" "libpng" "libdrm" "libevdev" "libdecor" "xorg-xwayland" "pipewire" "glib2" "fontconfig" "mesa" "systemd-libs" "seatd" "libdisplay-info" "libliftoff" "lcms2" "vulkan-icd-loader" "libxcb" "xcb-util-errors" "xcb-util-wm" "xcb-util-renderutil")
    conflicts=('aqueous-git' 'aqueous-git-intel' 'aqueous-git-dms' 'aqueous-core-bin' 'aqueous<0.7.0-2' 'aqueous-bin<0.7.0-2')
    _stage_component core
}

package_aqueous-session() {
    pkgdesc="Aqueous session"
    depends=("aqueous-core=$pkgver-$pkgrel" "bash" "jq" "coreutils" "uwsm" "dbus" "systemd" "ghostty" "grim" "slurp" "wl-clipboard" "libnotify" "xdg-desktop-portal" "xdg-desktop-portal-gtk")
    conflicts=('aqueous-git' 'aqueous-git-intel' 'aqueous-git-dms' 'aqueous-session-bin' 'aqueous<0.7.0-2' 'aqueous-bin<0.7.0-2')
    backup=('etc/xdg/aqueous/wm.toml' 'etc/xdg/aqueous/outputs.toml' 'etc/xdg/uwsm/env-aqueous' 'etc/xdg/menus/aqueous-applications.menu' 'etc/xdg/xdg-desktop-portal-aqueous/config')
    _stage_component session
}

package_aqueous-welcome() {
    pkgdesc="Aqueous welcome"
    depends=("aqueous-session=$pkgver-$pkgrel" "gtk4" "shelly" "sudo")
    conflicts=('aqueous-git' 'aqueous-git-intel' 'aqueous-git-dms' 'aqueous-welcome-bin' 'aqueous<0.7.0-2' 'aqueous-bin<0.7.0-2')
    _stage_component welcome
}

package_xdg-desktop-portal-aqueous() {
    pkgdesc="Aqueous portal"
    depends=("libinih" "pipewire" "wayland" "systemd-libs" "xdg-desktop-portal")
    conflicts=('aqueous-git' 'aqueous-git-intel' 'aqueous-git-dms' 'xdg-desktop-portal-aqueous-bin' 'aqueous<0.7.0-2' 'aqueous-bin<0.7.0-2')
    _stage_component portal
}

package_aqueous-integration-dms() {
    pkgdesc="Aqueous integration-dms"
    depends=("aqueous-session=$pkgver-$pkgrel" "xdg-desktop-portal-aqueous=$pkgver-$pkgrel")
    conflicts=('aqueous-git' 'aqueous-git-intel' 'aqueous-git-dms' 'aqueous-integration-dms-bin' 'aqueous<0.7.0-2' 'aqueous-bin<0.7.0-2')
    _stage_component integration-dms
}

package_aqueous-integration-noctalia() {
    pkgdesc="Aqueous integration-noctalia"
    depends=("aqueous-session=$pkgver-$pkgrel")
    conflicts=('aqueous-git' 'aqueous-git-intel' 'aqueous-git-dms' 'aqueous-integration-noctalia-bin' 'aqueous<0.7.0-2' 'aqueous-bin<0.7.0-2')
    _stage_component integration-noctalia
}

package_aqueous-integration-pearl() {
    pkgdesc="Aqueous integration-pearl"
    depends=("aqueous-session=$pkgver-$pkgrel")
    conflicts=('aqueous-git' 'aqueous-git-intel' 'aqueous-git-dms' 'aqueous-integration-pearl-bin' 'aqueous<0.7.0-2' 'aqueous-bin<0.7.0-2')
    _stage_component integration-pearl
}

package_aqueous-shell-dms() {
    pkgdesc="Aqueous aqueous-shell-dms"
    depends=("aqueous-integration-dms=$pkgver-$pkgrel" "dms-shell")
    conflicts=('aqueous-git' 'aqueous-git-intel' 'aqueous-git-dms' 'aqueous-shell-dms-bin')
    : # Dependency-only preset.
}

package_aqueous-shell-noctalia() {
    pkgdesc="Aqueous aqueous-shell-noctalia"
    depends=("aqueous-integration-noctalia=$pkgver-$pkgrel" "noctalia")
    conflicts=('aqueous-git' 'aqueous-git-intel' 'aqueous-git-dms' 'aqueous-shell-noctalia-bin')
    : # Dependency-only preset.
}

package_aqueous-shell-pearl() {
    pkgdesc="Aqueous aqueous-shell-pearl"
    depends=("aqueous-integration-pearl=$pkgver-$pkgrel" "pearl")
    conflicts=('aqueous-git' 'aqueous-git-intel' 'aqueous-git-dms' 'aqueous-shell-pearl-bin')
    : # Dependency-only preset.
}

package_aqueous() {
    pkgdesc="Aqueous aqueous"
    depends=("aqueous-core=$pkgver-$pkgrel" "aqueous-session=$pkgver-$pkgrel" "aqueous-welcome=$pkgver-$pkgrel" "xdg-desktop-portal-aqueous=$pkgver-$pkgrel" "aqueous-integration-dms=$pkgver-$pkgrel" "aqueous-integration-noctalia=$pkgver-$pkgrel" "aqueous-integration-pearl=$pkgver-$pkgrel")
    conflicts=('aqueous-git' 'aqueous-git-intel' 'aqueous-git-dms' 'aqueous-bin')
    install=aqueous.install
    : # Dependency-only preset.
}
