{
  lib,
  stdenv,
  binutils,
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
  libliftoff,
  libpng,
  libxkbcommon,
  linkFarm,
  makeWrapper,
  mesa,
  meson,
  ninja,
  pipewire,
  pixman,
  pkg-config,
  python3,
  ripgrep,
  runCommand,
  scdoc,
  systemd,
  vulkan-loader,
  wayland,
  wayland-protocols,
  wayland-scanner,
  wlroots_0_20,
  xwayland,
  zig_0_16,
  aqueousSource ? lib.cleanSourceWith {
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
          "docs"
          "welcome"
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
  version ? "0.7.0",
}:

assert lib.assertMsg (lib.versionAtLeast wayland-protocols.version "1.49")
  "Aqueous requires wayland-protocols 1.49 or newer";

let
  src = aqueousSource;
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
    buildInputs = (old.buildInputs or [ ]) ++ [ libliftoff ];
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
      "${src}/compositor/patches/wlroots/0018-pointer-constraint-initial-region.patch"
      "${src}/compositor/patches/wlroots/0019-overlay-backend-recovery.patch"
      "${src}/compositor/patches/wlroots/0020-vulkan-sync-failure-handling.patch"
      "${src}/compositor/patches/wlroots/0021-drm-lease-lifetime.patch"
      "${src}/compositor/patches/wlroots/0022-pointer-enter-serial-validation.patch"
      "${src}/compositor/patches/wlroots/0023-commit-timing-v1.patch"
      "${src}/compositor/patches/wlroots/0024-protocol-versions.patch"
    ];

    # These match compositor/scripts/build-wlroots-render-hook.sh. Appending
    # makes these values win if the Nixpkgs derivation supplies broader defaults.
    mesonFlags = (old.mesonFlags or [ ]) ++ [
      "-Dexamples=false"
      "-Dxwayland=enabled"
      "-Drenderers=vulkan"
      "-Dbackends=drm,libinput,x11"
      "-Dallocators=gbm"
      "-Dlibliftoff=enabled"
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

  wlrootsLibrary = "${lib.getLib aqueousWlroots}/lib/libwlroots-0.20.so";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "aqueous-core";
  inherit version src;

  strictDeps = true;

  nativeBuildInputs = [
    binutils
    jq
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
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-config-cache"
    zig build --system "${zigDeps}" -Dcpu=baseline -Doptimize=ReleaseSafe \
      --prefix "$TMPDIR/aqueous-config-dist"
    popd

    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-config-cache" \
      zig build --build-file settingsApplication/build.zig --system "${zigDeps}" test test-driver -Dmodel-only=true --prefix "$TMPDIR/aqueous-config-tests"
    AQUEOUS_CONFIG_BINARY="$TMPDIR/aqueous-config-dist/bin/aqueous-config" \
    AQUEOUSCTL_BINARY="$TMPDIR/aqueous-dist/bin/aqueousctl" \
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
    cmp "$TMPDIR/aqueous-dist/lib/aqueous/libwlroots-0.20.so" \
      "${wlrootsLibrary}"
    readelf -d "$TMPDIR/aqueous-dist/bin/aqueous" | \
      grep -F '$ORIGIN/../lib/aqueous' >/dev/null
    if readelf -d "$TMPDIR/aqueous-dist/bin/aqueous" | grep -qi scenefx; then
      echo "Aqueous unexpectedly links SceneFX" >&2
      exit 1
    fi

    bash settingsApplication/tests/test-backend.sh "$TMPDIR/aqueous-config-tests/bin/aqueous-backend-test"
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    AQUEOUS_COMPOSITOR_DIST="$TMPDIR/aqueous-dist" \
    AQUEOUS_CONFIG_BINARY="$TMPDIR/aqueous-config-dist/bin/aqueous-config" \
      DESTDIR="$TMPDIR/core-stage" PREFIX="$out" SYSCONFDIR="$out/etc" \
      bash packaging/stage-component.sh core
    mkdir -p "$out"
    cp -a "$TMPDIR/core-stage/$out/." "$out/"
    patchShebangs "$out/bin"
    wrapProgram "$out/bin/aqueous" \
      --prefix PATH : "${lib.makeBinPath [ xwayland pipewire ]}"
    wrapProgram "$out/bin/aqueous-config" \
      --prefix PATH : "$out/bin:${lib.makeBinPath [ fontconfig glib systemd dbus ]}"

    runHook postInstall
  '';

  passthru = {
    inherit aqueousWlroots zigDeps;
    inherit src;
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
