{
  lib,
  stdenv,
  binutils,
  coreutils,
  dbus,
  fetchurl,
  fontconfig,
  gzip,
  glib,
  gnutar,
  jq,
  libevdev,
  libinput,
  libxkbcommon,
  linkFarm,
  makeWrapper,
  noctalia-shell,
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
          "plugin"
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
  version ? "0.4.8",
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

  wlrootsLibrary = "${lib.getLib aqueousWlroots}/lib/libwlroots-0.20.so";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "aqueous";
  inherit version src;

  strictDeps = true;

  nativeBuildInputs = [
    binutils
    makeWrapper
    pkg-config
    scdoc
    wayland-scanner
    xwayland
    zig_0_16
  ];

  buildInputs = [
    aqueousWlroots
    libevdev
    libinput
    libxkbcommon
    pixman
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
    patchShebangs plugin/tests
    substituteInPlace compositor/build.zig \
      --replace-fail '"/bin/sh", "-c"' '"${stdenv.shell}", "-c"'
    substituteInPlace packaging/aqueous-wm.sh \
      --replace-fail "/usr/bin/aqueous -c /usr/bin/aqueous-init" \
        "$out/bin/aqueous -c $out/bin/aqueous-init"
    substituteInPlace packaging/aqueous-init \
      --replace-fail "/usr/share/aqueous" "$out/share/aqueous"
    substituteInPlace packaging/enable-noctalia-plugin.sh \
      --replace-fail "/usr/share/aqueous" "$out/share/aqueous"
    substituteInPlace packaging/noctalia/config.toml \
      --replace-fail "/usr/share/aqueous" "$out/share/aqueous"
    substituteInPlace packaging/noctalia.service \
      --replace-fail "/usr/bin/noctalia" "${lib.getExe noctalia-shell}" \
      --replace-fail "/usr/lib/aqueous/enable-noctalia-plugin" \
        "$out/libexec/aqueous/enable-noctalia-plugin"
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

    pushd plugin/helper
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-helper-local-cache"
    zig build \
      -Dcpu=baseline \
      -Doptimize=ReleaseSafe \
      --prefix "$TMPDIR/aqueous-helper-dist" \
      install
    popd

    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck

    required=(
      bin/aqueous
      bin/aqueousctl
      lib/aqueous/libwlroots-0.20.so
      share/man/man1/aqueous.1
      share/man/man1/aqueousctl.1
      share/aqueous-protocols/stable/aqueous-window-info-v1.xml
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

    plugin/tests/test-helper.sh \
      "$TMPDIR/aqueous-helper-dist/bin/aqueous-config"

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -a "$TMPDIR/aqueous-dist/." "$out/"
    install -Dm755 "$TMPDIR/aqueous-helper-dist/bin/aqueous-config" \
      "$out/bin/aqueous-config"

    install -Dm755 packaging/aqueous-init "$out/bin/aqueous-init"
    install -Dm755 packaging/aqueous-wm.sh "$out/bin/aqueous-wm"
    install -Dm755 packaging/enable-noctalia-plugin.sh \
      "$out/libexec/aqueous/enable-noctalia-plugin"

    install -Dm644 aqueous.desktop \
      "$out/share/wayland-sessions/aqueous.desktop"
    install -Dm644 packaging/aqueous-portals.conf \
      "$out/share/xdg-desktop-portal/aqueous-portals.conf"
    install -Dm644 packaging/uwsm/env-aqueous \
      "$out/share/aqueous/uwsm/env-aqueous"

    install -Dm644 wm.toml "$out/share/aqueous/wm.toml"
    install -Dm644 outputs.toml "$out/share/aqueous/outputs.toml"

    install -Dm644 packaging/aqueous-session.target \
      "$out/lib/systemd/user/aqueous-session.target"
    install -Dm644 packaging/noctalia.service \
      "$out/lib/systemd/user/noctalia.service"
    install -Dm644 packaging/aqueous.tmpfiles \
      "$out/lib/tmpfiles.d/aqueous.conf"
    install -Dm644 packaging/udev/70-aqueous-uaccess.rules \
      "$out/lib/udev/rules.d/70-aqueous-uaccess.rules"

    install -Dm644 packaging/noctalia/config.toml \
      "$out/share/aqueous/noctalia/config.toml"
    install -Dm644 plugin/catalog.toml \
      "$out/share/aqueous/noctalia-plugins/catalog.toml"
    install -Dm644 plugin/settings/plugin.toml \
      "$out/share/aqueous/noctalia-plugins/settings/plugin.toml"
    install -Dm644 plugin/settings/widget.luau \
      "$out/share/aqueous/noctalia-plugins/settings/widget.luau"
    install -Dm644 plugin/settings/panel.luau \
      "$out/share/aqueous/noctalia-plugins/settings/panel.luau"
    install -Dm644 plugin/settings/aqueous.png \
      "$out/share/aqueous/noctalia-plugins/settings/aqueous.png"
    install -Dm644 plugin/settings/translations/en.json \
      "$out/share/aqueous/noctalia-plugins/settings/translations/en.json"
    install -Dm644 packaging/wallpapers/*.avif \
      -t "$out/share/aqueous/wallpapers"

    install -Dm644 packaging/greetd/config.toml.example \
      "$out/share/doc/aqueous/greetd-config.toml.example"
    install -Dm644 README.md "$out/share/doc/aqueous/README.md"
    mkdir -p "$out/share/licenses"
    cp -a compositor/LICENSES "$out/share/licenses/aqueous"

    patchShebangs "$out/bin" "$out/libexec/aqueous"

    wrapProgram "$out/bin/aqueous" \
      --prefix PATH : "${lib.makeBinPath [ xwayland ]}"
    wrapProgram "$out/bin/aqueous-wm" \
      --prefix PATH : "${lib.makeBinPath [ coreutils systemd ]}"
    wrapProgram "$out/bin/aqueous-init" \
      --prefix PATH : "${lib.makeBinPath [ coreutils dbus systemd uwsm ]}"
    wrapProgram "$out/bin/aqueous-config" \
      --prefix PATH : "${lib.makeBinPath [ fontconfig glib noctalia-shell ]}"
    wrapProgram "$out/libexec/aqueous/enable-noctalia-plugin" \
      --prefix PATH : "${lib.makeBinPath [ coreutils noctalia-shell ]}"

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
    license = lib.licenses.gpl3Only;
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
