#!/usr/bin/env bash
# No host installation or compositor connection. Every writable path is private.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
base=$(mktemp -d /tmp/aqueous-git-packages.XXXXXXXX)
trap 'rm -rf -- "$base"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reject() { if "$@" > "$base/rejected.log" 2>&1; then fail "Unexpected success: $*"; fi; }
files() { find "$1" \( -type f -o -type l \) -printf '%P\n' | sort; }
source "$root/packaging/components/common.sh"
build=$base/build
for path in bin/aqueous bin/aqueous-activity-launch bin/aqueousctl bin/aqueous-config lib/aqueous/libwlroots-0.20.so \
    share/man/man1/aqueous.1 share/man/man1/aqueousctl.1 \
    share/aqueous-protocols/experimental/aqueous-capture-color-v1.xml; do
    install -d "$build/$(dirname "$path")"
    printf '#!/bin/sh\nexit 0\n' > "$build/$path"
    chmod 755 "$build/$path"
done
install -d "$build/share/aqueous" "$build/share/pkgconfig"
printf '{"schema":1,"output_retry_testing":false,"display_preview_acceptance":false}\n' > "$build/share/aqueous/build-policy.json"
printf 'prefix=/usr\ndatarootdir=${prefix}/share\npkgdatadir=${pc_sysrootdir}${datarootdir}/aqueous-protocols\nName: aqueous-protocols\nDescription: Aqueous protocols\nVersion: 1\n' > "$build/share/pkgconfig/aqueous-protocols.pc"
export AQUEOUS_COMPOSITOR_DIST=$build AQUEOUS_CONFIG_DIST=$build AQUEOUS_CONFIG_BINARY=$build/bin/aqueous-config
DESTDIR="$base/stable" PREFIX=/usr "$root/packaging/stage-component.sh" core
files "$base/stable" > "$base/stable-files"
for channel in git; do
    instance=aqueous-$channel
    jq -n --arg instance "$instance" '{schema:1,instance:$instance}' > "$build/share/aqueous/build-instance.json"
    DESTDIR="$base/$channel" PREFIX=/usr "$root/packaging/git/stage.sh" "$channel"
    files "$base/$channel" > "$base/$channel-files"
    [[ -z $(comm -12 "$base/stable-files" "$base/$channel-files") ]] || fail 'Stable file overlap'
    [[ ! -e $base/$channel/etc && ! -e $base/$channel/usr/lib/systemd && ! -e $base/$channel/usr/share/wayland-sessions ]] || fail 'Unexpected session integration'
    [[ -x $base/$channel/usr/bin/aqueous-$channel && -x $base/$channel/usr/bin/aqueousctl-$channel && -x $base/$channel/usr/bin/aqueous-config-$channel ]] || fail 'Missing suffixed command'
    # Relocated paths exercise the launchers without placing anything under /usr.
    DESTDIR="$base/relocated-$channel" PREFIX="$base/prefix-$channel" "$root/packaging/git/stage.sh" "$channel"
    mv "$base/relocated-$channel$base/prefix-$channel" "$base/prefix-$channel"
    private=$base/prefix-$channel/lib/$instance
    cat > "$private/bin/aqueousctl" <<'SH'
#!/usr/bin/env bash
jq -n --arg instance "$AQUEOUS_INSTANCE" --arg executable "$0" --arg library "$LD_LIBRARY_PATH" \
 --arg config "${AQUEOUS_CONFIG:-}" --arg socket "${AQUEOUS_SOCKET:-}" --arg display "${WAYLAND_DISPLAY:-}" \
 '{instance:$instance,executable:$executable,library:$library,config:$config,socket:$socket,display:$display}'
SH
    printf '#!/bin/sh\nexec aqueousctl "$@"\n' > "$private/bin/aqueous-config"
    chmod 755 "$private/bin/aqueousctl" "$private/bin/aqueous-config"
    AQUEOUS_INSTANCE=aqueous AQUEOUS_CONFIG=/stable/wm.toml AQUEOUS_SOCKET=/stable/ipc.sock WAYLAND_DISPLAY=stable \
        "$base/prefix-$channel/bin/aqueous-config-$channel" > "$base/routing.json"
    jq -e --arg instance "$instance" --arg private "$private" \
        '.instance==$instance and .executable==($private+"/bin/aqueousctl") and (.library|startswith($private+"/lib/aqueous")) and .config=="" and .socket=="" and .display=="aqueous-git-unselected"' "$base/routing.json" >/dev/null
    AQUEOUS_INSTANCE=$instance AQUEOUS_CONFIG=/git/wm.toml AQUEOUS_SOCKET=/git/ipc.sock WAYLAND_DISPLAY=git-display \
        "$base/prefix-$channel/bin/aqueous-config-$channel" > "$base/routing.json"
    jq -e '.config=="/git/wm.toml" and .socket=="/git/ipc.sock" and .display=="git-display"' "$base/routing.json" >/dev/null
    AQUEOUS_INSTANCE=aqueous AQUEOUS_GIT_CONFIG=/explicit/wm.toml AQUEOUS_GIT_SOCKET=/explicit/ipc.sock AQUEOUS_GIT_WAYLAND_DISPLAY=explicit-display \
        "$base/prefix-$channel/bin/aqueous-config-$channel" > "$base/routing.json"
    jq -e '.config=="/explicit/wm.toml" and .socket=="/explicit/ipc.sock" and .display=="explicit-display"' "$base/routing.json" >/dev/null
    recipe=$root/packaging/arch/aqueous-core-$channel/PKGBUILD
    bash -c 'set -eu; source "$1"; [[ ${provides+x} != x && ${conflicts+x} != x && ${install+x} != x ]]; [[ $pkgname == "$2" ]]; [[ ${#replaces[@]} == 1 && ${replaces[0]} == aqueous-core-intel-git ]]; for dep in "${depends[@]}"; do case $dep in dms*|noctalia*|pearl*|aqueous|aqueous-core) exit 1;; esac; done' _ "$recipe" "aqueous-core-$channel"
    reject env DESTDIR="$base/reused-$channel" PREFIX=/usr AQUEOUS_CONFIG_DIST="$base/missing" "$root/packaging/git/stage.sh" "$channel"
done
printf '{"schema":1,"instance":"aqueous"}\n' > "$build/share/aqueous/build-instance.json"
reject env DESTDIR="$base/wrong-instance" PREFIX=/usr "$root/packaging/git/stage.sh" git
printf 'PASS: stable/Git file ownership, metadata, relocatable private tools and endpoint isolation\n'
if [[ $# == 0 ]]; then exit; fi
[[ $# == 3 && ($3 == git || $3 == intel-git) ]] || fail 'Expected compositor-dist helper-dist git|intel-git'
compositor=$(realpath "$1"); helper=$(realpath "$2"); channel=$3; instance=aqueous-$channel
DESTDIR="$base/real-stage" PREFIX="$base/real-prefix" AQUEOUS_COMPOSITOR_DIST="$compositor" AQUEOUS_CONFIG_DIST="$helper" "$root/packaging/git/stage.sh" "$channel"
mv "$base/real-stage$base/real-prefix" "$base/real-prefix"
private=$base/real-prefix/lib/$instance
cmp "$compositor/lib/aqueous/libwlroots-0.20.so" "$private/lib/aqueous/libwlroots-0.20.so"
readelf -d "$private/bin/aqueous" | grep -F '$ORIGIN/../lib/aqueous' >/dev/null
export HOME=$base/home XDG_CONFIG_HOME=$base/config XDG_STATE_HOME=$base/state XDG_RUNTIME_DIR=$base/run
mkdir -p "$HOME/.config/aqueous" "$XDG_CONFIG_HOME/aqueous" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
# Both stable locations exist, including the historical home-first layout path.
printf '# stable wm\n[layout]\ndefault="tile"\n' > "$XDG_CONFIG_HOME/aqueous/wm.toml"
printf '# stable layout\n' > "$HOME/.config/aqueous/layout.toml"
export AQUEOUS_INSTANCE=aqueous AQUEOUS_CONFIG=$XDG_CONFIG_HOME/aqueous/wm.toml AQUEOUS_SOCKET=/stable/ipc.sock WAYLAND_DISPLAY=stable
"$base/real-prefix/bin/aqueous-config-$channel" snapshot > "$base/snapshot.json"
jq -e --arg prefix "$XDG_CONFIG_HOME/$instance/" '.ok and all(.files[]; (.path|startswith($prefix)))' "$base/snapshot.json" >/dev/null
[[ -d $XDG_STATE_HOME/$instance/config-writer && ! -e $XDG_STATE_HOME/aqueous ]] || fail 'Stable journal path touched'
jq '{protocol:1,expected_generation:.generation,changes:[],create_user_override:true}' "$base/snapshot.json" > "$base/request.json"
"$base/real-prefix/bin/aqueous-config-$channel" validate --shell none --request - < "$base/request.json" > "$base/candidate.json"
jq -e .ok "$base/candidate.json" >/dev/null
[[ $(cat "$HOME/.config/aqueous/layout.toml") == '# stable layout' ]] || fail 'Stable configuration changed'
# A user override must also use the compiled namespace, not the stable directory.
jq '{protocol:1,expected_generation:.generation,changes:[{id:"actions.toggle_start_menu",value:"private-launcher"}],create_user_override:true}' "$base/snapshot.json" > "$base/request.json"
"$base/real-prefix/bin/aqueous-config-$channel" apply --shell none --request - < "$base/request.json" > "$base/applied.json"
jq -e .ok "$base/applied.json" >/dev/null
grep -q private-launcher "$XDG_CONFIG_HOME/$instance/wm.toml"
! grep -q private-launcher "$XDG_CONFIG_HOME/aqueous/wm.toml"
printf 'PASS: real private binaries, wlroots RPATH, helper source isolation and user overrides\n'
