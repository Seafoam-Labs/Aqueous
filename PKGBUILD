pkgname=aqueous-git
pkgver=0.1.0
pkgrel=1
pkgdesc="A .NET 10 GTK4-based desktop environment components using Astal"
arch=('x86_64' 'aarch64')
url="https://github.com/your-username/aqueous"
license=('GPL3')
depends=('gtk4' 'socat' 'libastal-io' 'libastal-apps' 'libastal-auth' 'libastal-battery' 'libastal-bluetooth' 'libastal-cava' 'libastal-greet' 'libastal-mpris' 'libastal-network' 'libastal-notifd' 'libastal-powerprofiles' 'libastal-tray' 'libastal-wireplumber')
makedepends=('dotnet-sdk-10.0' 'clang' 'zlib' 'krb5')
provides=('aqueous')
conflicts=('aqueous')
source=('aqueous.desktop' 'aqueous-wayfire-setup.sh')
sha256sums=('SKIP' 'SKIP')
install=aqueous.install

_rid_map() {
    case "$CARCH" in
        x86_64) echo "linux-x64" ;;
        aarch64) echo "linux-arm64" ;;
        *) return 1 ;;
    esac
}

build() {
    local rid=$(_rid_map)
    # The source is expected to be in the build directory
    dotnet publish "$srcdir/Aqueous/Aqueous.csproj" \
        -c Release \
        -r "$rid" \
        --self-contained true \
        -o "$srcdir/publish" \
        /p:PublishAot=true
}

package() {
    install -d "$pkgdir/usr/lib/aqueous"
    cp -r "$srcdir/publish/"* "$pkgdir/usr/lib/aqueous/"
    
    # Symlink binary
    install -d "$pkgdir/usr/bin"
    ln -s /usr/lib/aqueous/Aqueous "$pkgdir/usr/bin/aqueous"
    
    # App launcher script
    install -m755 "$srcdir/Aqueous/Features/AppLauncher/aqueous-applauncher" "$pkgdir/usr/bin/aqueous-applauncher"
    
    # SnapTo script
    install -m755 "$srcdir/Aqueous/Features/SnapTo/aqueous-snapto" "$pkgdir/usr/bin/aqueous-snapto"
    
    # Screenlock script
    install -m755 "$srcdir/Aqueous/Features/Screenlock/aqueous-screenlock" "$pkgdir/usr/bin/aqueous-screenlock"
    
    # Wayfire setup script
    install -Dm755 "$srcdir/aqueous-wayfire-setup.sh" "$pkgdir/usr/lib/aqueous/aqueous-wayfire-setup.sh"
    
    # Desktop entry
    install -Dm644 "$srcdir/aqueous.desktop" "$pkgdir/usr/share/applications/aqueous.desktop"
}

