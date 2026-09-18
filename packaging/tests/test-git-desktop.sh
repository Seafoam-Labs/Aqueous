#!/usr/bin/env bash
# Private staging, mock services, and optional real native worker checks.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
base=$(mktemp -d /tmp/aqueous-git-desktop-test.XXXXXXXX)
trap 'rm -rf -- "$base"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
files() { find "$1" \( -type f -o -type l \) -printf '%P\n' | sort; }
components=(session welcome portal integration-dms integration-noctalia integration-pearl)
mkdir -p "$base/fixture/bin" "$base/fixture/share/aqueous"
printf '#!/bin/sh\nexit 0\n' > "$base/fixture/bin/aqueous-welcome"
chmod +x "$base/fixture/bin/aqueous-welcome"
printf 'fixture license\n' > "$base/LICENSE"
export AQUEOUS_WELCOME_BINARY=$base/fixture/bin/aqueous-welcome AQUEOUS_PORTAL_BINARY=$base/fixture/bin/aqueous-welcome
export AQUEOUS_PORTAL_CHOOSER_BINARY=$base/fixture/bin/aqueous-welcome AQUEOUS_PORTAL_LICENSE=$base/LICENSE
for component in "${components[@]}"; do
    DESTDIR="$base/stable-$component" "$root/packaging/stage-component.sh" "$component"
    files "$base/stable-$component"
done | sort -u > "$base/stable.files"
for channel in git; do
    instance=aqueous-$channel
    if [[ $channel == git ]]; then desktop=Aqueous-Git; app=org.aqueous.Git.Welcome; else desktop=Aqueous-Intel-Git; app=org.aqueous.IntelGit.Welcome; fi
    cp "$base/fixture/bin/aqueous-welcome" "$base/fixture/xdg-desktop-portal-$instance"
    jq -n --arg instance "$instance" '{schema:1,instance:$instance}' > "$base/fixture/build-instance.json"
    jq '. + {test_hooks:false}' "$base/fixture/build-instance.json" > "$base/fixture/share/aqueous/build-instance.json"
    : > "$base/$channel.files"
    for component in "${components[@]}"; do
        DESTDIR="$base/$channel-$component" AQUEOUS_WELCOME_DIST="$base/fixture" AQUEOUS_PORTAL_DIST="$base/fixture" \
            "$root/packaging/git/desktop-stage.sh" "$channel" "$component"
        files "$base/$channel-$component" >> "$base/$channel.files"
    done
    [[ -z $(sort "$base/$channel.files" | uniq -d) ]] || fail 'Desktop components share files'
    sort -o "$base/$channel.files" "$base/$channel.files"
    [[ -z $(comm -12 "$base/stable.files" "$base/$channel.files") ]] || fail 'Stable desktop file conflict'
    session=$base/$channel-session
    runtime=$session/usr/lib/$instance/session-runtime.sh
    bash -n "$runtime"
    for command in wm init shell-action; do sh -n "$session/usr/bin/aqueous-$command-$channel"; done
    grep -q "Exec=uwsm start -- aqueous-wm-$channel" "$session/usr/share/wayland-sessions/$instance.desktop"
    grep -q "DesktopNames=$desktop" "$session/usr/share/wayland-sessions/$instance.desktop"
    grep -q "OnlyShowIn=$desktop;" "$base/$channel-welcome/etc/xdg/autostart/$app.desktop"
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
    grep -qx 'ExecStart=/usr/bin/pearl-git' "$pearl_units/$instance-pearl.service"
    grep -qx '\[Install\]' "$pearl_units/$instance-pearl.service"
    grep -qx 'WantedBy=graphical-session.target' "$pearl_units/$instance-pearl.service"
    [[ -L $pearl_units/graphical-session.target.wants/$instance-pearl.service ]]
    [[ -f $pearl_units/pearl-git.service.d/60-$instance-selection.conf ]]
    grep -qx 'pearl_binary=pearl-git' "$runtime"
    grep -qx 'pearl_control=pearlctl-git' "$runtime"
    recipe=$root/packaging/arch/aqueous-desktop-$channel/PKGBUILD
    bash -c 'set -eu; source "$1"; "package_aqueous-shell-pearl-$2"; [[ ${#depends[@]} == 2 && ${depends[1]} == pearl-git ]]' _ "$recipe" "$channel"
    bash -c '
        set -eu
        source "$1"
        _stage() { :; }
        # Every split component must replace only its own retired Intel package.
        for package in "${pkgname[@]}"; do
            (
                unset replaces
                "package_$package"
                [[ ${#replaces[@]} == 1 && ${replaces[0]} == "${package%-git}-intel-git" ]]
            )
        done
        # Review sees the placeholder; the final build sees a VCS revision.
        # Neither may tie an independently published core to that version.
        for version in "$pkgver" 0.7.0.r999.gabcdef0; do
            pkgver=$version
            "package_aqueous-session-$2"
            [[ ${depends[0]} == "aqueous-core-$2>=0.7.0" ]]
            "package_aqueous-desktop-$2"
            [[ ${provides+x} != x && ${conflicts+x} != x && ${install+x} != x ]]
            [[ ${#depends[@]} == 7 && ${depends[0]} == "aqueous-core-$2>=0.7.0" ]]
            for dep in "${depends[@]:1}"; do [[ $dep == *"-$2=$pkgver-$pkgrel" ]]; done
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
        if "$runtime" condition pearl; then fail 'Unselected shell starts'; fi
        [[ -e $XDG_RUNTIME_DIR/$instance/welcome-session.json && ! -e $XDG_RUNTIME_DIR/aqueous ]]
        printf 'version=1\nshell="none"\n' > "$XDG_CONFIG_HOME/$instance/session.toml"
        [[ $($runtime active-selection) == dms && $($runtime selection) == none ]]
        AQUEOUS_NESTED=1 "$runtime" prepare-session
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
[[ $# == 4 ]] || fail 'Expected welcome-dist portal-dist channel portal-license'
welcome=$(realpath "$1"); portal=$(realpath "$2"); channel=$3; license=$(realpath "$4")
case $channel in git) app=org.aqueous.Git.Welcome;; intel-git) app=org.aqueous.IntelGit.Welcome;; *) exit 2;; esac
instance=aqueous-$channel
prefix=$base/real-prefix
for component in session welcome portal; do
    DESTDIR="$base/real-$component" PREFIX="$prefix" SYSCONFDIR="$prefix/etc" AQUEOUS_WELCOME_DIST="$welcome" AQUEOUS_PORTAL_DIST="$portal" AQUEOUS_PORTAL_LICENSE="$license" \
        "$root/packaging/git/desktop-stage.sh" "$channel" "$component"
    mkdir -p "$prefix"
    cp -a "$base/real-$component$prefix/." "$prefix/"
done
# Metadata mismatch and test builds must never stage into a production package.
if DESTDIR="$base/bad" AQUEOUS_WELCOME_DIST="$welcome" "$root/packaging/git/desktop-stage.sh" "$(if [[ $channel == git ]]; then echo intel-git; else echo git; fi)" welcome >/dev/null 2>&1; then fail 'Accepted wrong welcome identity'; fi
strings "$prefix/lib/$instance/xdg-desktop-portal-$instance" > "$base/portal.strings"
grep -qx "org.freedesktop.impl.portal.desktop.${instance//-/_}" "$base/portal.strings"
grep -qx "xdg-desktop-portal-$instance" "$base/portal.strings"
export HOME=$base/real-home XDG_CONFIG_HOME=$base/real-config XDG_STATE_HOME=$base/real-state XDG_RUNTIME_DIR=$base/real-run
export XDG_CURRENT_DESKTOP=Aqueous WAYLAND_DISPLAY=fixture AQUEOUS_NESTED=0
mkdir -p "$HOME" "$XDG_CONFIG_HOME/aqueous" "$XDG_CONFIG_HOME/$instance" "$XDG_RUNTIME_DIR"
printf 'version=1\nshell="dms"\n' > "$XDG_CONFIG_HOME/aqueous/session.toml"
printf 'version=1\nshell="none"\n' > "$XDG_CONFIG_HOME/$instance/session.toml"
binary=$prefix/bin/aqueous-welcome-$channel
# --first-run on stable must exit before GTK tries to connect to any display.
"$binary" --first-run
[[ $("$binary" --worker selection) == none ]]
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
cat > "$prefix/bin/aqueous-config-$channel" <<'SH'
#!/bin/sh
case $1 in
 snapshot) printf '{"ok":true,"generation":"g","fields":[{"id":"actions.screenshot","value":"dms screenshot region"}],"raw_files":{},"capabilities":["shell_none","schema_fields","validate","generation_check","stdin_requests","apply_result_v1","operation_receipts_v1","candidate_impact_v1","recoverable_commit_v1"]}\n';;
 validate|apply) cat > "$FIXTURE_ROOT/request"; printf '{"ok":true,"raw_files":{}}\n';;
 *) exit 1;;
esac
SH
chmod +x "$prefix/bin/aqueous-config-$channel"
printf '{"accept":true}\n' | "$binary" --worker setup none > "$base/events"
jq -e 'select(.kind=="done")' "$base/events" >/dev/null
jq -e --arg command "aqueous-shell-action-$channel screenshot" '.changes[0].value==$command' "$base/request" >/dev/null
[[ -e $XDG_STATE_HOME/$instance/welcome-v1 && ! -e $XDG_STATE_HOME/aqueous ]]
[[ -e $XDG_CONFIG_HOME/autostart/$app.desktop && ! -e $XDG_CONFIG_HOME/autostart/org.aqueous.Welcome.desktop ]]
grep -q "aqueous-shell-action-$channel chooser" "$XDG_CONFIG_HOME/xdg-desktop-portal-$instance/config"
grep -q 'shell="dms"' "$XDG_CONFIG_HOME/aqueous/session.toml"
printf 'PASS: real welcome worker isolation, helper routing, completion, portal configuration and compiled portal identity\n'
cat > "$prefix/bin/sudo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == -p && $2 == '[sudo] password for %p: ' && $3 == -- && $4 == shelly ]]
shift 3
export FIXTURE_ELEVATED=1
exec "$@"
SH
chmod +x "$prefix/bin/sudo"
cat > "$prefix/bin/shelly" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == list ]]; then
    if [[ -f $FIXTURE_ROOT/packages ]]; then cat "$FIXTURE_ROOT/packages"; else printf '[]\n'; fi
    exit
fi
[[ $1 == install && $2 == standard ]]
[[ ${FIXTURE_ELEVATED:-0} == 1 ]]
printf '%s\n' "$*" > "$FIXTURE_ROOT/install-log"
jq -n --args '$ARGS.positional | map(select(. != "--ui-mode") | {Name:.,Id:.})' -- "${@:3}" > "$FIXTURE_ROOT/packages"
if [[ ${OMIT_PEARL:-0} == 1 ]]; then
    jq 'map(select(.Name != "pearl-git"))' "$FIXTURE_ROOT/packages" > "$FIXTURE_ROOT/packages-next"
    mv "$FIXTURE_ROOT/packages-next" "$FIXTURE_ROOT/packages"
fi
printf '[JSON]%s[/JSON]\n' "$(printf '%s' '{"$kind":"alpm.info","EventType":"TransactionDone"}' | base64 -w0)"
SH
chmod +x "$prefix/bin/shelly"
printf '#!/bin/sh\nexit 0\n' > "$prefix/bin/pearl-git"
chmod +x "$prefix/bin/pearl-git"
pearl_setup() {
    local pid output input event status=0
    # Keep the UI transport open until the install completes; EOF is cancellation.
    coproc WORKER { timeout 20 "$1" --worker setup pearl; }
    pid=$WORKER_PID
    exec {output}<&"${WORKER[0]}" {input}>&"${WORKER[1]}"
    : > "$base/events"
    while IFS= read -r -u "$output" event; do
        printf '%s\n' "$event" >> "$base/events"
        if [[ $(jq -r .kind <<< "$event") == review ]]; then printf '{"accept":true}\n' >&"$input"; fi
    done
    exec {output}<&- {input}>&-
    wait "$pid" || status=$?
    return "$status"
}
for runtime_mode in installed missing; do
    if [[ $runtime_mode == installed ]]; then setup_binary=$binary
    else
        setup_binary=$prefix/lib/$instance/bin/aqueous-welcome
        export AQUEOUS_SESSION_RUNTIME=$base/missing-runtime
    fi
    pearl_setup "$setup_binary" || { cat "$base/events" >&2; exit 1; }
    grep -qx "install standard pearl-git aqueous-shell-pearl-$channel --ui-mode" "$base/install-log"
    jq -e 'select(.kind=="done")' "$base/events" >/dev/null
    [[ $("$setup_binary" --worker selection) == pearl ]]
done
# A leftover executable plus an installed preset is not proof Pearl installed.
printf 'version=1\nshell="none"\n' > "$XDG_CONFIG_HOME/$instance/session.toml"
rm "$XDG_STATE_HOME/$instance/welcome-v1"
if OMIT_PEARL=1 pearl_setup "$binary"; then fail 'Accepted a missing Pearl package'; fi
[[ $("$binary" --worker selection) == none && ! -e $XDG_STATE_HOME/$instance/welcome-v1 ]]
printf 'PASS: Pearl and matching Git preset requested and verified, including missing-runtime recovery\n'
