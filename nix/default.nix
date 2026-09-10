{
  lib,
  stdenv,
  binutils,
  coreutils,
  dbus,
  fetchurl,
  fontconfig,
  freetype,
  shaderc,
  vulkan-headers,
  gzip,
  glib,
  gnutar,
  inih,
  jq,
  libdrm,
  libevdev,
  libinput,
  libpng,
  libxkbcommon,
  linkFarm,
  makeWrapper,
  mesa,
  meson,
  ninja,
  noctalia-shell,
  pipewire,
  pixman,
  pkg-config,
  python3,
  ripgrep,
  runCommand,
  scdoc,
  systemd,
  uwsm,
  vulkan-loader,
  wayland,
  wayland-protocols,
  wayland-scanner,
  wlroots_0_20,
  xwayland,
  zig_0_16,
  src ? lib.cleanSourceWith {
    src = ../.;
    filter = path: _type:
      let
        root = toString ../.;
        pathString = toString path;
        relative = lib.removePrefix "${root}/" pathString;
        topLevel = lib.head (lib.splitString "/" relative);
        name = baseNameOf (toString path);
      in
      pathString == root
      || (
        builtins.elem topLevel [
          "README.md"
          "aqueous.desktop"
          "compositor"
          "nix"
          "outputs.toml"
          "packaging"
          "settingsApplication"
          "wm.toml"
        ]
        && !(builtins.elem name [
          ".deps"
          ".venv"
          ".zig-cache"
          "__pycache__"
          "result"
          "zig-cache"
          "zig-out"
          "zig-pkg"
        ])
      );
  },
  version ? "0.6.0",
}:

assert lib.assertMsg (lib.versionAtLeast wayland-protocols.version "1.49")
  "Aqueous requires wayland-protocols 1.49 or newer";

let
  zigDeps = import ./zig-deps.nix {
    inherit
      fetchurl
      gzip
      gnutar
      linkFarm
      runCommand
      ;
  };

  aqueousWlroots = wlroots_0_20.overrideAttrs (old: {
    pname = "aqueous-wlroots";
    version = "0.20.2";
    src = fetchurl {
      url = "https://gitlab.freedesktop.org/wlroots/wlroots/-/archive/0.20.2/wlroots-0.20.2.tar.gz";
      hash = "sha256-lyx6xEsXgo9HAr+ufNg0c0aj+1ssEHbPosP87axew0M=";
    };

    patches = (old.patches or [ ]) ++ [
      "${src}/compositor/patches/wlroots/0001-aqueous-vulkan-render-hook.patch"
      "${src}/compositor/patches/wlroots/0002-fix-hdr-min-luminance.patch"
      "${src}/compositor/patches/wlroots/0003-color-management-v1-srgb-compat.patch"
      "${src}/compositor/patches/wlroots/0004-scene-sdr-white-level.patch"
      "${src}/compositor/patches/wlroots/0005-drm-expose-edid-hdr-static-metadata.patch"
      "${src}/compositor/patches/wlroots/0006-color-management-v1-windows-hdr.patch"
      "${src}/compositor/patches/wlroots/0007-scene-precise-position.patch"
      "${src}/compositor/patches/wlroots/0008-xwayland-native-scaling.patch"
      "${src}/compositor/patches/wlroots/0009-surface-preferred-scale-override.patch"
      "${src}/compositor/patches/wlroots/0010-output-layer-sync-and-test.patch"
      "${src}/compositor/patches/wlroots/0011-scene-output-layer-promotion.patch"
      "${src}/compositor/patches/wlroots/0012-syncobj-release-on-buffer-detach.patch"
      "${src}/compositor/patches/wlroots/0013-fifo-v1.patch"
      "${src}/compositor/patches/wlroots/0014-screencopy-10bit-sdr-shm.patch"
      "${src}/compositor/patches/wlroots/0015-ext-capture-formats-and-color.patch"
      "${src}/compositor/patches/wlroots/0016-toplevel-icon-lifetime.patch"
      "${src}/compositor/patches/wlroots/0017-xdg-toplevel-drag-v1.patch"
    ];

    # These match compositor/scripts/build-wlroots-render-hook.sh. Appending
    # makes these values win if the Nixpkgs derivation supplies broader defaults.
    mesonFlags = (old.mesonFlags or [ ]) ++ [
      "-Dexamples=false"
      "-Dxwayland=enabled"
      "-Drenderers=vulkan"
      "-Dbackends=drm,libinput,x11"
      "-Dallocators=gbm"
      "-Dsession=enabled"
      "-Dcolor-management=enabled"
    ];

    # The pinned fetchurl source has no GitLab fetcher metadata for wlroots's
    # original meta.homepage inheritance.
    meta = {
      description = "Aqueous's private patched wlroots build";
      homepage = "https://gitlab.freedesktop.org/wlroots/wlroots";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
    };
  });

  xdpwSource = fetchurl {
    url = "https://github.com/emersion/xdg-desktop-portal-wlr/archive/refs/tags/v0.8.4.tar.gz";
    hash = "sha256-MSKWbUarEI9QVSW8skmPkSG0Ru6EOPv863Onofoa1AA=";
  };

  wlrootsLibrary = "${lib.getLib aqueousWlroots}/lib/libwlroots-0.20.so";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "aqueous";
  inherit version src;

  strictDeps = true;

  nativeBuildInputs = [
    binutils
    gzip
    makeWrapper
    meson
    ninja
    python3
    shaderc
    pkg-config
    scdoc
    wayland-scanner
    xwayland
    zig_0_16
  ];

  buildInputs = [
    aqueousWlroots
    freetype
    vulkan-headers
    inih
    libdrm
    libevdev
    libinput
    libpng
    libxkbcommon
    mesa
    pixman
    pipewire
    systemd
    vulkan-loader
    wayland
    wayland-protocols
    wayland-scanner
  ];

  nativeCheckInputs = [
    jq
    python3
    ripgrep
  ];

  # This monorepo has two Zig build roots, so use explicit phases instead of
  # the single-project phases installed by Zig's setup hook.
  dontUseZigConfigure = true;
  dontUseZigBuild = true;
  dontUseZigCheck = true;
  dontUseZigInstall = true;

  postPatch = ''
    patchShebangs settingsApplication/packaging settingsApplication/tests
    substituteInPlace compositor/build.zig \
      --replace-fail '"/bin/sh", "-c"' '"${stdenv.shell}", "-c"'
    substituteInPlace packaging/aqueous-wm.sh \
      --replace-fail "/usr/bin/aqueous -c /usr/bin/aqueous-init" \
        "$out/bin/aqueous -c $out/bin/aqueous-init"
    substituteInPlace packaging/aqueous-init \
      --replace-fail "/usr/share/aqueous" "$out/share/aqueous"
    substituteInPlace packaging/noctalia/config.toml \
      --replace-fail "/usr/share/aqueous" "$out/share/aqueous"
    substituteInPlace packaging/noctalia.service \
      --replace-fail "/usr/bin/noctalia" "${lib.getExe noctalia-shell}"
    substituteInPlace \
      packaging/portal/org.freedesktop.impl.portal.desktop.aqueous.service \
      packaging/portal/xdg-desktop-portal-aqueous.service \
      --replace-fail "/usr/lib/aqueous/xdg-desktop-portal-aqueous" \
        "$out/libexec/aqueous/xdg-desktop-portal-aqueous"
    substituteInPlace aqueous.desktop \
      --replace-fail "Exec=uwsm start -- aqueous-wm" \
        "Exec=${lib.getExe uwsm} start -- $out/bin/aqueous-wm" \
      --replace-fail "TryExec=uwsm" "TryExec=${lib.getExe uwsm}"
  '';

  buildPhase = ''
    runHook preBuild

    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"

    pushd compositor
    zig build \
      --system "${zigDeps}" \
      -Dcpu=baseline \
      -Doptimize=ReleaseSafe \
      -Dxwayland \
      -Dllvm \
      -Dman-pages=true \
      -Dversion-string="${finalAttrs.version}" \
      -Dwlroots-render-hook-library="${wlrootsLibrary}" \
      --prefix "$TMPDIR/aqueous-dist" \
      install
    popd

    pushd settingsApplication
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-settings-cache"
    zig build --system "${zigDeps}" -Dcpu=baseline -Doptimize=ReleaseSafe \
      --prefix "$TMPDIR/aqueous-settings-dist"
    popd

    mkdir -p "$TMPDIR/xdpw-src"
    ${gnutar}/bin/tar -xzf "${xdpwSource}" \
      --strip-components=1 -C "$TMPDIR/xdpw-src"
    patch --fuzz=0 -d "$TMPDIR/xdpw-src" -Np1 < \
      packaging/portal/0001-rename-backend-for-aqueous.patch
    sh packaging/portal/build-aqueous-portal.sh \
      "$TMPDIR/xdpw-src" \
      "$TMPDIR/aqueous-portal-build" \
      "$TMPDIR/aqueous-portal-dist"

    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-settings-cache" \
      zig build --build-file settingsApplication/build.zig --system "${zigDeps}" test test-driver -Dmodel-only=true --prefix "$TMPDIR/aqueous-settings-tests"
    AQUEOUS_SETTINGS_BINARY="$TMPDIR/aqueous-settings-dist/bin/aqueous-settings" \
      bash settingsApplication/tests/test-packaging.sh

    AQUEOUS_WLROOTS_PREFIX="${lib.getDev aqueousWlroots}" \
      LD_LIBRARY_PATH="${lib.getLib aqueousWlroots}/lib" \
      bash compositor/scripts/test-ext-capture-formats.sh

    required=(
      bin/aqueous
      bin/aqueousctl
      lib/aqueous/libwlroots-0.20.so
      share/man/man1/aqueous.1
      share/man/man1/aqueousctl.1
      share/aqueous-protocols/stable/aqueous-window-info-v1.xml
      share/aqueous-protocols/stable/aqueous-window-management-v1.xml
      share/aqueous-protocols/stable/aqueous-input-management-v1.xml
      share/aqueous-protocols/stable/aqueous-xkb-bindings-v1.xml
      share/aqueous-protocols/stable/aqueous-xkb-config-v1.xml
      share/aqueous-protocols/stable/aqueous-libinput-config-v1.xml
      share/aqueous-protocols/stable/aqueous-layer-shell-v1.xml
      share/aqueous-protocols/experimental/aqueous-capture-color-v1.xml
    )
    for path in "''${required[@]}"; do
      test -e "$TMPDIR/aqueous-dist/$path"
    done
    test -x \
      "$TMPDIR/aqueous-portal-dist/usr/lib/aqueous/xdg-desktop-portal-aqueous"

    cmp "$TMPDIR/aqueous-dist/lib/aqueous/libwlroots-0.20.so" \
      "${wlrootsLibrary}"
    readelf -d "$TMPDIR/aqueous-dist/bin/aqueous" | \
      grep -F '$ORIGIN/../lib/aqueous' >/dev/null
    if readelf -d "$TMPDIR/aqueous-dist/bin/aqueous" | grep -qi scenefx; then
      echo "Aqueous unexpectedly links SceneFX" >&2
      exit 1
    fi

    bash settingsApplication/tests/test-backend.sh "$TMPDIR/aqueous-settings-tests/bin/aqueous-backend-test"
    AQUEOUS_PORTAL_EXEC="$out/libexec/aqueous/xdg-desktop-portal-aqueous" \
      packaging/tests/test-portal-packaging.sh \
      "$TMPDIR/aqueous-portal-dist/usr/lib/aqueous/xdg-desktop-portal-aqueous"

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -a "$TMPDIR/aqueous-dist/." "$out/"
    AQUEOUS_SETTINGS_BINARY="$TMPDIR/aqueous-settings-dist/bin/aqueous-settings" \
      PREFIX="$out" SYSCONFDIR="$out/etc" bash settingsApplication/packaging/install.sh

    install -Dm755 \
      "$TMPDIR/aqueous-portal-dist/usr/lib/aqueous/xdg-desktop-portal-aqueous" \
      "$out/libexec/aqueous/xdg-desktop-portal-aqueous"

    install -Dm755 packaging/aqueous-init "$out/bin/aqueous-init"
    install -Dm755 packaging/aqueous-wm.sh "$out/bin/aqueous-wm"

    install -Dm644 aqueous.desktop \
      "$out/share/wayland-sessions/aqueous.desktop"
    install -Dm644 packaging/aqueous-portals.conf \
      "$out/share/xdg-desktop-portal/aqueous-portals.conf"
    install -Dm644 packaging/portal/aqueous.portal \
      "$out/share/xdg-desktop-portal/portals/aqueous.portal"
    install -Dm644 \
      packaging/portal/org.freedesktop.impl.portal.desktop.aqueous.service \
      "$out/share/dbus-1/services/org.freedesktop.impl.portal.desktop.aqueous.service"
    install -Dm644 packaging/uwsm/env-aqueous \
      "$out/share/aqueous/uwsm/env-aqueous"

    install -Dm644 wm.toml "$out/share/aqueous/wm.toml"
    install -Dm644 outputs.toml "$out/share/aqueous/outputs.toml"

    install -Dm644 packaging/aqueous-session.target \
      "$out/lib/systemd/user/aqueous-session.target"
    install -Dm644 packaging/portal/xdg-desktop-portal-aqueous.service \
      "$out/lib/systemd/user/xdg-desktop-portal-aqueous.service"
    install -Dm644 packaging/noctalia.service \
      "$out/lib/systemd/user/noctalia.service"
    install -Dm644 packaging/aqueous.tmpfiles \
      "$out/lib/tmpfiles.d/aqueous.conf"
    install -Dm644 packaging/udev/70-aqueous-uaccess.rules \
      "$out/lib/udev/rules.d/70-aqueous-uaccess.rules"

    install -Dm644 packaging/noctalia/config.toml \
      "$out/share/aqueous/noctalia/config.toml"
    install -Dm644 packaging/ghostty/config.ghostty \
      "$out/share/aqueous/ghostty/config.ghostty"
    install -Dm644 packaging/wallpapers/*.avif \
      -t "$out/share/aqueous/wallpapers"

    install -Dm644 packaging/greetd/config.toml.example \
      "$out/share/doc/aqueous/greetd-config.toml.example"
    install -Dm644 README.md "$out/share/doc/aqueous/README.md"
    mkdir -p "$out/share/licenses"
    cp -a compositor/LICENSES "$out/share/licenses/aqueous"
    install -Dm644 "$TMPDIR/xdpw-src/LICENSE" \
      "$out/share/licenses/aqueous/xdg-desktop-portal-wlr/LICENSE"

    patchShebangs "$out/bin" "$out/libexec/aqueous"

    wrapProgram "$out/bin/aqueous" \
      --prefix PATH : "${lib.makeBinPath [ xwayland pipewire ]}"
    wrapProgram "$out/bin/aqueous-wm" \
      --prefix PATH : "${lib.makeBinPath [ coreutils systemd ]}"
    wrapProgram "$out/bin/aqueous-init" \
      --prefix PATH : "${lib.makeBinPath [ coreutils dbus systemd uwsm ]}"
    wrapProgram "$out/bin/aqueous-settings" \
      --prefix PATH : "${lib.makeBinPath [ fontconfig glib systemd dbus ]}"
    wrapProgram "$out/bin/aqueous-config" \
      --prefix PATH : "$out/bin:${lib.makeBinPath [ fontconfig glib systemd dbus ]}"

    runHook postInstall
  '';

  passthru = {
    inherit aqueousWlroots zigDeps;
    providedSessions = [ "aqueous" ];
  };

  meta = {
    description = "Single-process Wayland compositor with native tiling and Vulkan effects";
    homepage = "https://github.com/Seafoam-Labs/Aqueous";
    changelog = "https://github.com/Seafoam-Labs/Aqueous/releases/tag/v${finalAttrs.version}";
    license = [ lib.licenses.gpl3Only lib.licenses.mit ];
    mainProgram = "aqueous";
    maintainers = [
      {
        name = "Zoey Bauer";
        email = "zoey.erin.bauer@gmail.com";
      }
    ];
    platforms = lib.platforms.linux;
  };
})
