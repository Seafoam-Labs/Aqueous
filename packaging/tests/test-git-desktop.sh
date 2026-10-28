#!/usr/bin/env bash
# Private staging, mock services, and optional real portal artifact checks.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
base=$(mktemp -d /tmp/aqueous-git-desktop-test.XXXXXXXX)
trap 'rm -rf -- "$base"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
files() { find "$1" \( -type f -o -type l \) -printf '%P\n' | sort; }
components=(session portal integration-dms integration-noctalia integration-pearl)
mkdir -p "$base/fixture/bin"
printf '#!/bin/sh\nexit 0\n' > "$base/fixture/bin/fixture-tool"
chmod +x "$base/fixture/bin/fixture-tool"
printf 'fixture license\n' > "$base/LICENSE"
export AQUEOUS_PICKER_BINARY=$base/fixture/bin/fixture-tool
export AQUEOUS_PORTAL_BINARY=$base/fixture/bin/fixture-tool
export AQUEOUS_PORTAL_CHOOSER_BINARY=$base/fixture/bin/fixture-tool AQUEOUS_PORTAL_LICENSE=$base/LICENSE
for component in "${components[@]}"; do
    DESTDIR="$base/stable-$component" "$root/packaging/stage-component.sh" "$component"
    files "$base/stable-$component"
done | sort -u > "$base/stable.files"
for channel in git; do
    instance=aqueous-$channel
    if [[ $channel == git ]]; then desktop=Aqueous-Git; app=org.aqueous.Git.Welcome; else desktop=Aqueous-Intel-Git; app=org.aqueous.IntelGit.Welcome; fi
    cp "$base/fixture/bin/fixture-tool" "$base/fixture/xdg-desktop-portal-$instance"
    jq -n --arg instance "$instance" '{schema:1,instance:$instance}' > "$base/fixture/build-instance.json"
    : > "$base/$channel.files"
    for component in "${components[@]}"; do
        DESTDIR="$base/$channel-$component" AQUEOUS_PORTAL_DIST="$base/fixture" \
            "$root/packaging/git/desktop-stage.sh" "$channel" "$component"
        files "$base/$channel-$component" >> "$base/$channel.files"
    done
    # Reject portal builds from another instance, even without picker metadata.
    printf '{"schema":1,"instance":"aqueous"}\n' > "$base/fixture/build-instance.json"
    if DESTDIR="$base/rejected" AQUEOUS_PORTAL_DIST="$base/fixture" \
        "$root/packaging/git/desktop-stage.sh" "$channel" portal > "$base/rejected.log" 2>&1; then
        fail 'Accepted mismatched portal metadata'
    fi
    grep -q 'Wrong portal build identity' "$base/rejected.log"
    jq -n --arg instance "$instance" '{schema:1,instance:$instance}' > "$base/fixture/build-instance.json"
    [[ -z $(sort "$base/$channel.files" | uniq -d) ]] || fail 'Desktop components share files'
    sort -o "$base/$channel.files" "$base/$channel.files"
    [[ -z $(comm -12 "$base/stable.files" "$base/$channel.files") ]] || fail 'Stable desktop file conflict'
    session=$base/$channel-session
    runtime=$session/usr/lib/$instance/session-runtime.sh
    bash -n "$runtime"
    test ! -e "$base/$channel-portal/usr/bin/aqueous-portal-picker-$channel"
    ! grep -qE 'aqueous-welcome|Welcome\.desktop|aqueous-portal-picker' "$base/$channel.files" || fail 'Retired UI was staged'
    ! grep -q 'setup_command\|aqueous-welcome' "$runtime"
    ! grep -q aqueous-portal-picker "$runtime"
    grep -q "^pearl_capture_picker=/usr/lib/pearl-git/pearl-capture-picker$" "$runtime"
    ! grep -q -- "--choose" "$runtime"
    for command in wm init shell-action; do sh -n "$session/usr/bin/aqueous-$command-$channel"; done
    grep -q "Exec=uwsm start -- aqueous-wm-$channel" "$session/usr/share/wayland-sessions/$instance.desktop"
    grep -q "DesktopNames=$desktop" "$session/usr/share/wayland-sessions/$instance.desktop"
    grep -q "desktop.${instance//-/_}" "$base/$channel-portal/usr/share/xdg-desktop-portal/portals/$instance.portal"
    grep -q 'AQUEOUS_SOCKET AQUEOUS_INSTANCE PATH LD_LIBRARY_PATH' "$session/usr/bin/aqueous-init-$channel"
    [[ ! -e $base/$channel-integration-dms/etc/xdg/quickshell ]] || fail 'Git installed global DMS plugins'
    dms_unit=$base/$channel-integration-dms/usr/lib/systemd/user/$instance-dms.service
    grep -qx 'Type=exec' "$dms_unit"
    ! grep -q '^BusName=' "$dms_unit" || fail 'DMS wrapper duplicates the upstream notification BusName'
    for shell in dms noctalia; do
        shell_unit=$base/$channel-integration-$shell/usr/lib/systemd/user/$instance-$shell.service
        grep -qx 'KillMode=control-group' "$shell_unit"
        grep -qx 'SendSIGKILL=yes' "$shell_unit"
    done
    pearl_units=$base/$channel-integration-pearl/usr/lib/systemd/user
    grep -qx "ExecStart=/usr/lib/$instance/bin/aqueous-activity-launch /usr/bin/pearl-git" "$pearl_units/$instance-pearl.service"
    grep -qx '\[Install\]' "$pearl_units/$instance-pearl.service"
    grep -qx 'WantedBy=graphical-session.target' "$pearl_units/$instance-pearl.service"
    grep -qx 'StartLimitIntervalSec=60' "$pearl_units/$instance-pearl.service"
    grep -qx 'StartLimitBurst=5' "$pearl_units/$instance-pearl.service"
    [[ -L $pearl_units/graphical-session.target.wants/$instance-pearl.service ]]
    [[ -f $pearl_units/pearl-git.service.d/60-$instance-selection.conf ]]
    grep -qx 'pearl_binary=pearl-git' "$runtime"
    grep -qx 'pearl_control=pearlctl-git' "$runtime"
    recipe=$root/packaging/arch/aqueous-$channel/PKGBUILD
    bash -c 'set -eu; source "$1"; "package_aqueous-shell-pearl-$2"; [[ ${#depends[@]} == 4 && ${depends[0]} == "pearl-capture-picker-git>=1" && ${depends[1]} == "xdg-desktop-portal-aqueous-git=$pkgver-$pkgrel" && ${depends[2]} == "aqueous-integration-pearl-git=$pkgver-$pkgrel" && ${depends[3]} == pearl-git ]]' _ "$recipe" "$channel"
    bash -c '
        set -eu
        source "$1"
        _stage() { :; }
        _stage_core() { :; }
        [[ $pkgbase == aqueous-git && ${#pkgname[@]} == 11 ]]
        [[ " ${pkgname[*]} " == *" aqueous-core-git "* ]]
        [[ " ${pkgname[*]} " != *welcome* ]]
        for dep in "${makedepends[@]}"; do
            case $dep in gtk4) exit 1;; esac
        done
        ! declare -F package_aqueous-welcome-git >/dev/null
        # Only the renamed desktop meta package replaces a previous package.
        for package in "${pkgname[@]}"; do
            (
                unset replaces
                "package_$package"
                for dep in "${depends[@]}"; do
                    case $dep in *welcome*|shelly|sudo|gtk4) exit 1;; esac
                done
                if [[ $package == aqueous-git ]]; then
                    [[ ${replaces[*]} == aqueous-desktop-git ]]
                else
                    [[ ! -v replaces ]]
                fi
                for dep in "${depends[@]}"; do
                    case $dep in
                        aqueous-*-git=*|xdg-desktop-portal-aqueous-git=*)
                            [[ " ${pkgname[*]} " == *" ${dep%%=*} "* ]]
                            [[ $dep == *"=$pkgver-$pkgrel" ]];;
                    esac
                done
            )
        done
        # All components must resolve within the split at review and build time.
        for version in "$pkgver" 1.0.2.r999.gabcdef0; do
            pkgver=$version
            "package_aqueous-session-$2"
            [[ ${depends[0]} == "aqueous-core-$2=$pkgver-$pkgrel" ]]
            [[ ${conflicts[*]} == aqueous-welcome-git ]]
            unset conflicts
            "package_aqueous-$2"
            [[ ${provides[*]} == "aqueous-desktop-git=$pkgver-$pkgrel" && ${conflicts[*]} == aqueous-desktop-git && ${install+x} != x ]]
            [[ ${#depends[@]} == 7 && ${depends[0]} == "aqueous-shell-none-$2=$pkgver-$pkgrel" && ${depends[1]} == "aqueous-core-$2=$pkgver-$pkgrel" ]]
            for dep in "${depends[@]:2}"; do [[ $dep == *"-$2=$pkgver-$pkgrel" ]]; done
        done
    ' _ "$recipe" "$channel"
    (
        export HOME=$base/home-$channel XDG_CONFIG_HOME=$base/config-$channel XDG_STATE_HOME=$base/state-$channel XDG_RUNTIME_DIR=$base/run-$channel
        export AQUEOUS_SYSCONFDIR=$session/etc AQUEOUS_UNIT_DIR=$base/$channel-integration-dms/usr/lib/systemd/user AQUEOUS_SHARE_DIR=$session/usr/share/$instance
        export WAYLAND_DISPLAY=fixture AQUEOUS_NESTED=0
        mkdir -p "$HOME" "$XDG_CONFIG_HOME/aqueous" "$XDG_CONFIG_HOME/$instance" "$XDG_RUNTIME_DIR" "$base/bin"
        printf '#!/bin/sh\nexit 0\n' > "$base/bin/dms"; chmod +x "$base/bin/dms"
        export PATH=$base/bin:$PATH
        printf 'version=1\nshell="none"\n' > "$XDG_CONFIG_HOME/aqueous/session.toml"
        printf 'version=1\nshell="dms"\n' > "$XDG_CONFIG_HOME/$instance/session.toml"
        [[ $($runtime selection) == dms ]]
        XDG_CURRENT_DESKTOP=Aqueous "$runtime" external-condition
        if XDG_CURRENT_DESKTOP=Aqueous "$runtime" condition dms; then fail 'Git shell starts in stable'; fi
        export XDG_CURRENT_DESKTOP=$desktop
        "$runtime" prepare-session
        "$runtime" condition dms
        if "$runtime" action chooser > "$base/chooser.out" 2> "$base/chooser.err"; then fail 'DMS selected a source without a chooser'; fi
        [[ ! -s $base/chooser.out ]]
        grep -q 'No screen-sharing chooser configured' "$base/chooser.err"
        if "$runtime" condition pearl; then fail 'Unselected shell starts'; fi
        [[ -e $XDG_RUNTIME_DIR/$instance/welcome-session.json && ! -e $XDG_RUNTIME_DIR/aqueous ]]
        printf 'version=1\nshell="none"\n' > "$XDG_CONFIG_HOME/$instance/session.toml"
        [[ $($runtime active-selection) == dms && $($runtime selection) == none ]]
        AQUEOUS_NESTED=1 "$runtime" prepare-session
        "$runtime" prepare-session
        printf '#!/bin/sh\nprintf "terminal\\n"\n' > "$base/bin/ghostty"
        chmod +x "$base/bin/ghostty"
        printf '#!/bin/sh\ntouch "%s"\n' "$base/unexpected-welcome" > "$base/bin/aqueous-welcome-$channel"
        chmod +x "$base/bin/aqueous-welcome-$channel"
        [[ $("$runtime" action launcher) == terminal ]]
        if "$runtime" action chooser > "$base/chooser.out" 2> "$base/chooser.err"; then fail 'Shell-free session selected a source'; fi
        [[ ! -s $base/chooser.out ]]
        grep -q 'No screen-sharing chooser configured' "$base/chooser.err"
        if "$runtime" action lock > "$base/lock.log" 2>&1; then fail 'Missing locker reported success'; fi
        "$runtime" recover 2> "$base/recovery.log"
        [[ ! -e $base/unexpected-welcome ]] || fail 'Runtime launched retired Welcome'
        ! grep -q aqueous-welcome "$base/recovery.log"
        # Pearl Git alone must satisfy selection; never rely on host pearl.
        command() {
            if [[ $1 == -v && $2 == pearl ]]; then return 1; fi
            builtin command "$@"
        }
        export -f command
        printf '#!/bin/sh\nexit 0\n' > "$base/bin/pearl-git"
        printf '#!/bin/sh\nprintf "%%s\\n" "$*"\n' > "$base/bin/pearlctl-git"
        chmod +x "$base/bin/pearl-git" "$base/bin/pearlctl-git"
        export AQUEOUS_UNIT_DIR=$pearl_units
        printf 'version=1\nshell="pearl"\n' > "$XDG_CONFIG_HOME/$instance/session.toml"
        "$runtime" prepare-session
        "$runtime" condition pearl
        [[ $("$runtime" action launcher) == 'launcher toggle' ]]
        [[ $("$runtime" action lock) == lock ]]
        if "$runtime" condition dms; then fail 'Unselected DMS starts with Pearl'; fi
    )
done
printf 'PASS: desktop ownership, meta dependencies, login/portal identities, shell selection and session snapshots\n'
[[ $# != 0 ]] || exit 0
[[ $# == 3 ]] || fail 'Expected portal-dist channel portal-license'
portal=$(realpath "$1"); channel=$2; license=$(realpath "$3")
case $channel in git) app=org.aqueous.Git.Welcome;; intel-git) app=org.aqueous.IntelGit.Welcome;; *) exit 2;; esac
instance=aqueous-$channel
prefix=$base/real-prefix
for component in session portal; do
    DESTDIR="$base/real-$component" PREFIX="$prefix" SYSCONFDIR="$prefix/etc" AQUEOUS_PORTAL_DIST="$portal" AQUEOUS_PORTAL_LICENSE="$license" \
        "$root/packaging/git/desktop-stage.sh" "$channel" "$component"
    mkdir -p "$prefix"
    cp -a "$base/real-$component$prefix/." "$prefix/"
done
strings "$prefix/lib/$instance/xdg-desktop-portal-$instance" > "$base/portal.strings"
grep -qx "org.freedesktop.impl.portal.desktop.${instance//-/_}" "$base/portal.strings"
grep -qx "xdg-desktop-portal-$instance" "$base/portal.strings"
export HOME=$base/real-home XDG_CONFIG_HOME=$base/real-config XDG_STATE_HOME=$base/real-state XDG_RUNTIME_DIR=$base/real-run
export XDG_CURRENT_DESKTOP=Aqueous WAYLAND_DISPLAY=fixture AQUEOUS_NESTED=0
mkdir -p "$HOME" "$XDG_CONFIG_HOME/aqueous" "$XDG_CONFIG_HOME/$instance" "$XDG_RUNTIME_DIR"
printf 'version=1\nshell="dms"\n' > "$XDG_CONFIG_HOME/aqueous/session.toml"
printf 'version=1\nshell="none"\n' > "$XDG_CONFIG_HOME/$instance/session.toml"
export PATH=$prefix/bin:$PATH FIXTURE_ROOT=$base
export SERVICE_LOG=$base/service-log
for command in systemctl uwsm dbus-update-activation-environment; do
    cat > "$prefix/bin/$command" <<'SH'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "$SERVICE_LOG"
SH
    chmod +x "$prefix/bin/$command"
done
cat > "$prefix/bin/$instance" <<'SH'
#!/bin/sh
[ "$1" = -c ] || exit 91
export AQUEOUS_INSTANCE=${0##*/} WAYLAND_DISPLAY=git-fixture AQUEOUS_SOCKET="$XDG_RUNTIME_DIR/${0##*/}/fixture/ipc.sock"
export LD_LIBRARY_PATH="$(dirname "$0")/../lib/$AQUEOUS_INSTANCE/lib/aqueous"
printf '%s %s %s\n' "$XDG_CURRENT_DESKTOP" "$AQUEOUS_INSTANCE" "$2" >> "$SERVICE_LOG"
exec "$2"
SH
chmod +x "$prefix/bin/$instance"
mkdir -p "$XDG_CONFIG_HOME/ghostty"
printf '# existing terminal settings\n' > "$XDG_CONFIG_HOME/ghostty/config.ghostty"
"$prefix/bin/aqueous-wm-$channel"
grep -q " $instance $prefix/bin/aqueous-init-$channel" "$SERVICE_LOG"
grep -q 'uwsm finalize WAYLAND_DISPLAY AQUEOUS_SOCKET AQUEOUS_INSTANCE PATH LD_LIBRARY_PATH' "$SERVICE_LOG"
grep -q "xdg-desktop-portal-$instance.service" "$SERVICE_LOG"
if grep -q 'xdg-desktop-portal-aqueous.service\|aqueous-outputd.service' "$SERVICE_LOG"; then fail 'Git launcher controls a stable service'; fi
[[ -f $XDG_CONFIG_HOME/$instance/wm.toml && ! -e $XDG_CONFIG_HOME/aqueous/wm.toml ]]
[[ $(cat "$XDG_CONFIG_HOME/ghostty/config.ghostty") == '# existing terminal settings' ]]
grep -q "aqueous-shell-action-$channel chooser" "$prefix/etc/xdg/xdg-desktop-portal-$instance/config"
grep -q 'shell="dms"' "$XDG_CONFIG_HOME/aqueous/session.toml"
[[ ! -e $prefix/bin/aqueous-welcome-$channel && ! -d $prefix/etc/xdg/autostart ]]
printf 'PASS: compiled portal identity and session startup without bundled UI\n'
