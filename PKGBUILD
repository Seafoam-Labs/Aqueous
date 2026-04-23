pkgname=aqueous-git
pkgver=0.1.0
pkgrel=2
pkgdesc="A .NET 10 GTK4-based desktop environment components using Astal"
arch=('x86_64' 'aarch64')
url="https://github.com/your-username/aqueous"
license=('GPL3')
depends=('gtk4' 'socat' 'grim' 'slurp' 'wl-clipboard' 'cliphist' 'brightnessctl'
         'bluez' 'bluez-utils' 'iwd' 'vulkan-icd-loader' 'wlr-randr'
         'cairo' 'pango' 'libjpeg' 'libinput' 'libxkbcommon' 'wayland'
         'pixman' 'glm' 'libdrm' 'libevdev' 'nlohmann-json'
         'libastal-io' 'libastal-apps' 'libastal-auth' 'libastal-battery'
         'libastal-bluetooth' 'libastal-cava' 'libastal-greet' 'libastal-mpris'
         'libastal-network' 'libastal-notifd' 'libastal-powerprofiles'
         'libastal-river' 'libastal-tray' 'libastal-wireplumber'
         'nemo' 'polkit-gnome' 'xembedsniproxy')
makedepends=('dotnet-sdk-10.0' 'clang' 'zlib' 'krb5' 'git'
             'meson' 'ninja' 'cmake' 'wayland-protocols' 'glslang' 'vulkan-headers')
optdepends=('vulkan-validation-layers: Vulkan validation for HDR debugging')
provides=('aqueous' 'wayfire')
conflicts=('aqueous' 'wayfire')
source=("aqueous::git+${url}.git"
        "wayfire::git+https://github.com/WayfireWM/wayfire.git#commit=9a568ffd7a2af8780926da50f89908ec4f38bf3a"
        "wayfire-plugins-extra::git+https://github.com/WayfireWM/wayfire-plugins-extra.git"
        'aqueous.desktop'
        'aqueous-wayfire-setup.sh')
sha256sums=('SKIP' 'SKIP' 'SKIP' 'SKIP' 'SKIP')
install=aqueous.install

_rid_map() {
    case "$CARCH" in
        x86_64) echo "linux-x64" ;;
        aarch64) echo "linux-arm64" ;;
        *) return 1 ;;
    esac
}

pkgver() {
    cd aqueous
    git describe --long --tags 2>/dev/null | sed 's/^v//;s/\([^-]*-g\)/r\1/;s/-/./g' || echo "0.1.0.r$(git rev-list --count HEAD).g$(git rev-parse --short HEAD)"
}

build() {
    local rid=$(_rid_map)

    # --- Build Wayfire (pinned commit with bundled wlroots 0.20) ---
    cd "$srcdir/wayfire"
    git submodule update --init --recursive


    meson setup build \
        --prefix=/usr \
        --buildtype=release \
        -Duse_system_wlroots=disabled \
        -Duse_system_wfconfig=disabled
    ninja -C build

    # --- Build Aqueous ---
    dotnet publish "$srcdir/aqueous/Aqueous/Aqueous.csproj" \
        -c Release \
        -r "$rid" \
        --self-contained true \
        -o "$srcdir/publish" \
        /p:PublishAot=true

    # Screenshot tool
    dotnet publish "$srcdir/aqueous/AqueousScreenshot/AqueousScreenshot.csproj" \
        -c Release \
        -r "$rid" \
        --self-contained true \
        -o "$srcdir/publish-screenshot" \
        /p:PublishAot=true

    # Greeter
    dotnet publish "$srcdir/aqueous/AqueousGreeter/AqueousGreeter.csproj" \
        -c Release \
        -r "$rid" \
        --self-contained true \
        -o "$srcdir/publish-greeter" \
        /p:PublishAot=true
}

package() {
    # --- Install Wayfire ---
    cd "$srcdir/wayfire"
    DESTDIR="$pkgdir" ninja -C build install
    install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/wayfire-LICENSE"

    # --- Build and Install wayfire-plugins-extra ---
    cd "$srcdir/wayfire-plugins-extra"
    meson setup build --prefix=/usr
    ninja -C build
    DESTDIR="$pkgdir" ninja -C build install

    # --- Install Aqueous main binary ---
    install -d "$pkgdir/usr/lib/aqueous"
    cp -r "$srcdir/publish/"* "$pkgdir/usr/lib/aqueous/"

    install -d "$pkgdir/usr/bin"
    ln -s /usr/lib/aqueous/Aqueous "$pkgdir/usr/bin/aqueous"

    # Screenshot tool
    install -d "$pkgdir/usr/lib/aqueous-screenshot"
    cp -r "$srcdir/publish-screenshot/"* "$pkgdir/usr/lib/aqueous-screenshot/"
    ln -s /usr/lib/aqueous-screenshot/AqueousScreenshot "$pkgdir/usr/bin/aqueous-screenshot"

    # Greeter
    install -d "$pkgdir/usr/lib/aqueous-greeter"
    cp -r "$srcdir/publish-greeter/"* "$pkgdir/usr/lib/aqueous-greeter/"
    ln -s /usr/lib/aqueous-greeter/AqueousGreeter "$pkgdir/usr/bin/aqueous-greeter"

    # Shell scripts (all 9)
    install -m755 "$srcdir/aqueous/Aqueous/Features/AppLauncher/aqueous-applauncher" "$pkgdir/usr/bin/aqueous-applauncher"
    install -m755 "$srcdir/aqueous/Aqueous/Features/AudioSwitcher/aqueous-audioswitcher" "$pkgdir/usr/bin/aqueous-audioswitcher"
    install -m755 "$srcdir/aqueous/Aqueous/Features/Brightness/aqueous-brightness" "$pkgdir/usr/bin/aqueous-brightness"
    install -m755 "$srcdir/aqueous/Aqueous/Features/ClipboardManager/aqueous-clipboard" "$pkgdir/usr/bin/aqueous-clipboard"
    install -m755 "$srcdir/aqueous/Aqueous/Features/Network/aqueous-network" "$pkgdir/usr/bin/aqueous-network"
    install -m755 "$srcdir/aqueous/Aqueous/Features/Notifications/aqueous-notifications" "$pkgdir/usr/bin/aqueous-notifications"
    install -m755 "$srcdir/aqueous/Aqueous/Features/PowerProfiles/aqueous-powerprofiles" "$pkgdir/usr/bin/aqueous-powerprofiles"
    install -m755 "$srcdir/aqueous/Aqueous/Features/Screenlock/aqueous-screenlock" "$pkgdir/usr/bin/aqueous-screenlock"
    install -m755 "$srcdir/aqueous/Aqueous/Features/SnapTo/aqueous-snapto" "$pkgdir/usr/bin/aqueous-snapto"

    # Wayfire setup script
    install -Dm755 "$srcdir/aqueous-wayfire-setup.sh" "$pkgdir/usr/lib/aqueous/aqueous-wayfire-setup.sh"

    # Default wayfire.ini template
    install -Dm644 "$srcdir/aqueous/wayfire.ini" "$pkgdir/usr/share/aqueous/wayfire.ini"

    # Desktop entry
    install -Dm644 "$srcdir/aqueous.desktop" "$pkgdir/usr/share/applications/aqueous.desktop"

    # Set Nemo as default file manager
    install -d "$pkgdir/usr/share/applications"
    cat > "$pkgdir/usr/share/applications/mimeapps.list" <<EOF
[Default Applications]
inode/directory=nemo.desktop
EOF
}
