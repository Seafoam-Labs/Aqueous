{ lib, callPackage, stdenv, runCommand, symlinkJoin, python3, makeWrapper,
  coreutils, bash, jq, gawk, gnused, gnugrep, findutils, dbus, systemd, uwsm, grim, slurp, wl-clipboard, gtk4, zig_0_16,
  fetchurl, gnutar, meson, ninja, pkg-config, wayland, wayland-protocols,
  wayland-scanner, pipewire, inih, scdoc, zstd, linkFarm, libdrm, mesa }:
let
  core = callPackage ./core.nix { };
  inherit (core) version;
  src = core.src;
  portalSource = fetchurl {
    url = "https://github.com/emersion/xdg-desktop-portal-wlr/archive/refs/tags/v0.8.4.tar.gz";
    hash = "sha256-MSKWbUarEI9QVSW8skmPkSG0Ru6EOPv863Onofoa1AA=";
  };
  gobjectSource = fetchurl {
    url = "https://github.com/ghostty-org/zig-gobject/releases/download/0.9.0-2026-05-22-28-1/ghostty-gobject-0.9.0-2026-05-22-28-1.tar.zst";
    sha256 = "ac9bbfc49c6f1683ecbed8323157637935427bd75797ad516913fde4add506ca";
  };
  gobject = runCommand "aqueous-gobject-source" { nativeBuildInputs = [ zstd gnutar ]; } ''
    mkdir -p "$out"
    tar --zstd -xf ${gobjectSource} --strip-components=1 -C "$out"
  '';
  welcomeDeps = linkFarm "aqueous-welcome-dependencies" [
    { name = "gobject-0.3.1-Skun7CCNogB9kSZJzqLTf_TwzMPW3-Rqdw86UgxADV-z"; path = gobject; }
  ];
  # All component staging has a private root. Store references are introduced
  # only by the component that consumes them; core cannot refer to this set.
  stage = component: extra: runCommand "aqueous-${component}-${version}" {
    nativeBuildInputs = [ bash jq makeWrapper ];
  } ''
    cp -R ${src} source
    chmod -R u+w source
    ${extra}
    DESTDIR="$TMPDIR/stage" PREFIX="$out" SYSCONFDIR="$out/etc" \
      bash source/packaging/stage-component.sh ${component}
    mkdir -p "$out"
    cp -a "$TMPDIR/stage/$out/." "$out/"
    patchShebangs "$out"
    ${lib.optionalString (component == "welcome") ''
      wrapProgram "$out/bin/aqueous-welcome" --prefix PATH : '${lib.makeBinPath [ core ]}' \
        --set AQUEOUS_SESSION_RUNTIME '${sessionBase}/lib/aqueous/session-runtime.sh'
    ''}
    ${lib.optionalString (component == "session") ''
      wrapProgram "$out/lib/aqueous/session-runtime.sh" --prefix PATH : \
        '${lib.makeBinPath [ bash jq coreutils gawk gnugrep ]}'
    ''}
    ${lib.optionalString (lib.hasPrefix "integration-" component) ''
      find "$out/lib/systemd/user" -type f -exec sed -i \
        -e "s|$out/lib/aqueous/session-runtime.sh|${sessionBase}/lib/aqueous/session-runtime.sh|g" \
        -e "s|$out/bin/|/run/current-system/sw/bin/|g" {} +
    ''}
  '';
  sessionBase = stage "session" ''
    substituteInPlace source/packaging/aqueous-wm.sh \
      --replace-fail '/usr/bin/aqueous -c' '${core}/bin/aqueous -c'
  '';
  session = runCommand "aqueous-session-${version}" {
    nativeBuildInputs = [ makeWrapper ];
    passthru.providedSessions = [ "aqueous" ];
  } ''
    cp -R ${sessionBase} "$out"
    chmod -R u+w "$out"
    # Keep sessionBase paths: they own the runtime/defaults and remain in closure.
    substituteInPlace "$out/share/wayland-sessions/aqueous.desktop" \
      --replace-fail 'Exec=uwsm start -- aqueous-wm' "Exec=${uwsm}/bin/uwsm start -- $out/bin/aqueous-wm" \
      --replace-fail 'TryExec=uwsm' 'TryExec=${uwsm}/bin/uwsm'
    for command in aqueous-wm aqueous-init aqueous-shell-action; do
      wrapProgram "$out/bin/$command" --prefix PATH : \
        '${lib.makeBinPath [ core bash jq coreutils gawk gnused gnugrep findutils dbus systemd uwsm grim slurp wl-clipboard ]}'
    done
    # The compositor child must enter the wrapped initializer.
    substituteInPlace "$out/bin/.aqueous-wm-wrapped" \
      --replace-fail '${sessionBase}/bin/aqueous-init' "$out/bin/aqueous-init"
  '';
  welcomeBuild = stdenv.mkDerivation {
    pname = "aqueous-welcome-build";
    inherit version src;
    nativeBuildInputs = [ zig_0_16 pkg-config ];
    buildInputs = [ gtk4 ];
    dontUseZigConfigure = true;
    dontUseZigBuild = true;
    dontUseZigCheck = true;
    dontUseZigInstall = true;
    buildPhase = ''
      export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
      zig build --build-file welcome/build.zig --system ${welcomeDeps} \
        -Dcpu=baseline -Doptimize=ReleaseSafe --prefix "$out"
    '';
    dontInstall = true;
  };
  welcome = stage "welcome" ''
    export AQUEOUS_WELCOME_BINARY=${welcomeBuild}/bin/aqueous-welcome
  '';
  portalBuild = stdenv.mkDerivation {
    pname = "aqueous-portal-build";
    inherit version src;
    nativeBuildInputs = [ meson ninja pkg-config python3 wayland-scanner scdoc ];
    buildInputs = [ wayland wayland-protocols pipewire inih systemd libdrm mesa ];
    dontConfigure = true;
    buildPhase = ''
      mkdir portal-source
      tar -xzf ${portalSource} --strip-components=1 -C portal-source
      patch --fuzz=0 -d portal-source -Np1 < packaging/portal/0001-rename-backend-for-aqueous.patch
      sh packaging/portal/build-aqueous-portal.sh "$PWD/portal-source" "$TMPDIR/build" "$out"
      install -Dm644 portal-source/LICENSE "$out/LICENSE"
    '';
    dontInstall = true;
  };
  portal = stage "portal" ''
    export AQUEOUS_PORTAL_BINARY=${portalBuild}/usr/lib/aqueous/xdg-desktop-portal-aqueous
    export AQUEOUS_PORTAL_LICENSE=${portalBuild}/LICENSE
  '';
  chooser = stdenv.mkDerivation {
    pname = "aqueous-dms-chooser";
    inherit version src;
    nativeBuildInputs = [ zig_0_16 pkg-config ];
    buildInputs = [ ];
    dontUseZigConfigure = true;
    dontUseZigBuild = true;
    dontUseZigCheck = true;
    dontUseZigInstall = true;
    buildPhase = ''
      export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
      zig build --build-file packaging/portal/bridge/build.zig --system ${core.zigDeps} \
        -Dcpu=baseline -Doptimize=ReleaseSafe --prefix "$out"
    '';
    dontInstall = true;
  };
  integration = shell: stage "integration-${shell}" (lib.optionalString (shell == "dms") ''
    export AQUEOUS_PORTAL_CHOOSER_BINARY=${chooser}/bin/aqueous-dms-portal-chooser
  '');
  integrations = lib.genAttrs [ "dms" "noctalia" "pearl" ] integration;
  desktop = symlinkJoin {
    name = "aqueous-${version}";
    paths = [ core session welcome portal ] ++ builtins.attrValues integrations;
    passthru = { inherit core session welcome portal integrations; providedSessions = [ "aqueous" ]; };
  };
in { inherit core session welcome portal integrations desktop; }
