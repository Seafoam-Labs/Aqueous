# Maintainer: Zoey Bauer <zoey.erin.bauer@gmail.com>
# Maintainer: Caroline Snyder <hirpeng@gmail.com>
pkgname=aqueous-git
pkgver=0.1.0
pkgrel=3
pkgdesc="Aqueous Wayland window manager (River-based) with Noctalia bar"
arch=('x86_64' 'aarch64')
url="https://github.com/your-username/aqueous"
license=('GPL3')
depends=('wayland' 'wayland-protocols' 'libxkbcommon' 'libinput'
         'pixman' 'libdrm' 'libevdev' 'river'
         'noctalia-shell' 'tuigreet' 'libdecor', 'grim', 'aqueous-config')
optdepends=('ghostty: recommended terminal emulator',
'nemo: recommended file manager',
'shelly: recommended package manager',
'starfish: helpful package helper',
'firefox: web browser')
makedepends=('dotnet-sdk-10.0' 'clang' 'zlib' 'krb5' 'git')
provides=('aqueous')
conflicts=('aqueous')
source=("aqueous::git+${url}.git"
        'aqueous.desktop')
sha256sums=('SKIP' 'SKIP')

_rid_map() {
    case "$CARCH" in
        x86_64) echo "linux-x64" ;;
        aarch64) echo "linux-arm64" ;;
        *) return 1 ;;
    esac
}

pkgver() {
    cd aqueous
    git describe --long --tags 2>/dev/null | sed 's/^v//;s/\([^-]*-g\)/r\1/;s/-/./g' \
        || echo "0.1.0.r$(git rev-list --count HEAD).g$(git rev-parse --short HEAD)"
}

build() {
    local rid=$(_rid_map)
    dotnet publish "$srcdir/aqueous/Aqueous/Aqueous.csproj" \
        -c Release \
        -r "$rid" \
        --self-contained true \
        -o "$srcdir/publish-wm" \
        /p:PublishAot=true
}

package() {
    # Aqueous binary
    install -d "$pkgdir/usr/lib/aqueous-wm"
    cp -r "$srcdir/publish-wm/"* "$pkgdir/usr/lib/aqueous-wm/"
    install -d "$pkgdir/usr/bin"
    ln -s /usr/lib/aqueous-wm/Aqueous "$pkgdir/usr/bin/aqueous-wm"

    # Default WM config
    install -Dm644 "$srcdir/aqueous/wm.toml" "$pkgdir/usr/share/aqueous/wm.toml"

    # Wayland session entry (used by greetd/tuigreet etc.)
    install -Dm644 "$srcdir/aqueous.desktop" \
        "$pkgdir/usr/share/wayland-sessions/aqueous.desktop"
}
