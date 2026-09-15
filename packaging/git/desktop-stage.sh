#!/usr/bin/env bash
# Stage optional desktop components into an empty package root, never the host.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$root/packaging/components/common.sh"
case ${1:-} in git) desktop=Aqueous-Git; app=org.aqueous.Git.Welcome;; intel-git) desktop=Aqueous-Intel-Git; app=org.aqueous.IntelGit.Welcome;; *) aq_die 'Expected git|intel-git COMPONENT';; esac
channel=$1
component=${2:?Missing component}
instance=aqueous-$channel
bus=org.freedesktop.impl.portal.desktop.${instance//-/_}
prefix=${PREFIX:-/usr}
sysconf=${SYSCONFDIR:-/etc}
for path in "$prefix" "$sysconf"; do
    [[ $path =~ ^/[a-zA-Z0-9_./+-]+$ && /$path/ != */../* ]] || aq_die 'Use absolute, shell-safe install prefixes'
done
private=$prefix/lib/$instance
destination=${DESTDIR:?Set DESTDIR to an empty staging root}
aq_empty_root "$destination"
work=$(mktemp -d /tmp/aqueous-git-desktop-stage.XXXXXXXX)
trap 'rm -rf -- "$work"' EXIT
write() { install -d -- "$destination$(dirname -- "$1")"; cat > "$destination$1"; chmod "${2:-644}" "$destination$1"; }
copy() { install -Dm"${3:-644}" -- "$1" "$destination$2"; }
# Transform package-owned text only. The intermediate tokens avoid recursively
# renaming an already suffixed command. User configuration is never input here.
transform() {
    sed -E -e 's/aqueous/@INSTANCE@/g' -e 's/Aqueous/@DESKTOP@/g' \
        -e "s/org\.@INSTANCE@\.Welcome/$app/g" \
        -e "s/@INSTANCE@-(init|wm|welcome|shell-action)\b/aqueous-\1-$channel/g" \
        -e "s/@INSTANCE@ctl/aqueousctl-$channel/g" \
        -e "s/@INSTANCE@/$instance/g" -e "s/@DESKTOP@/$desktop/g" \
        -e "/^#!/!s|/usr/|$prefix/|g" -e "s|/etc/|$sysconf/|g" \
        -e "s|AQUEOUS_SYSCONFDIR:-/etc}|AQUEOUS_SYSCONFDIR:-$sysconf}|g"
}
case $component in
session)
    DESTDIR="$work/session" PREFIX=/usr SYSCONFDIR=/etc "$root/packaging/stage-component.sh" session
    while IFS= read -r -d '' file; do
        relative=${file#"$work/session"}
        # Sessions seed their own configuration on login; no tmpfiles preset.
        [[ $relative != /usr/lib/tmpfiles.d/aqueous.conf ]] || continue
        target=$(printf '%s' "$relative" | transform)
        case $relative in
            */wallpapers/*) copy "$file" "$target";;
            *) transform < "$file" | write "$target" "$(stat -c %a -- "$file")";;
        esac
    done < <(find "$work/session" -type f -print0 | sort -z)
    # Each Git session uses the native picker for DMS/Pearl/None. Avoid global
    # DMS plugin discovery paths owned by the stable and legacy integrations.
    sed -i -E 's@dms\) exec .*;;@dms) exec aqueous-welcome-'"$channel"' --choose;;@' "$destination$private/session-runtime.sh"
    # Git Pearl ships suffixed binaries; retain "pearl" as the selection ID.
    sed -i -e 's/^pearl_binary=pearl$/pearl_binary=pearl-git/' \
        -e 's/^pearl_control=pearlctl$/pearl_control=pearlctl-git/' "$destination$private/session-runtime.sh"
    # Applications activated through the user manager need the same toolchain
    # and instance marker as direct compositor children.
    sed -i '/^export AQUEOUS_SOCKET=/! s/AQUEOUS_SOCKET /AQUEOUS_SOCKET AQUEOUS_INSTANCE PATH LD_LIBRARY_PATH /g' "$destination$prefix/bin/aqueous-init-$channel"
    # Inherited stable packaging overrides must not retarget this desktop.
    sed -i '2a export AQUEOUS_SHARE_DIR="'"$prefix/share/$instance"'"\nexport AQUEOUS_SESSION_RUNTIME="'"$private/session-runtime.sh"'"\nexport AQUEOUS_SYSCONFDIR="'"$sysconf"'"\nexport AQUEOUS_UNIT_DIR="'"$prefix/lib/systemd/user"'"' "$destination$prefix/bin/aqueous-wm-$channel"
    # An explicit native init should not shut down legacy output services.
    sed -i '/^systemctl --user stop .*outputd.service/d' "$destination$prefix/bin/aqueous-wm-$channel"
    ;;
welcome)
    build=${AQUEOUS_WELCOME_DIST:?Set AQUEOUS_WELCOME_DIST}
    jq -e --arg instance "$instance" '. == {schema:1,instance:$instance,test_hooks:false}' "$build/share/aqueous/build-instance.json" >/dev/null || aq_die 'Wrong welcome build identity or test hooks enabled'
    copy "$build/bin/aqueous-welcome" "$private/bin/aqueous-welcome" 755
    # Keep the current display for GTK when setup is opened from another
    # desktop. The native worker invokes the suffixed helper, which isolates IPC.
    write "$prefix/bin/aqueous-welcome-$channel" 755 <<EOF
#!/bin/sh
export AQUEOUS_SESSION_RUNTIME="$private/session-runtime.sh"
export AQUEOUS_SHARE_DIR="$prefix/share/$instance"
export AQUEOUS_SYSCONFDIR="$sysconf"
export AQUEOUS_UNIT_DIR="$prefix/lib/systemd/user"
exec "$private/bin/aqueous-welcome" "\$@"
EOF
    transform < "$root/packaging/aqueous-welcome.desktop" | write "$prefix/share/applications/$app.desktop"
    transform < "$root/packaging/aqueous-welcome-autostart.desktop" | write "$sysconf/xdg/autostart/$app.desktop"
    ;;
portal)
    build=${AQUEOUS_PORTAL_DIST:?Set AQUEOUS_PORTAL_DIST}
    jq -e --arg instance "$instance" '. == {schema:1,instance:$instance}' "$build/build-instance.json" >/dev/null || aq_die 'Wrong portal build identity'
    copy "$build/xdg-desktop-portal-$instance" "$private/xdg-desktop-portal-$instance" 755
    copy "${AQUEOUS_PORTAL_LICENSE:?Set AQUEOUS_PORTAL_LICENSE}" "$prefix/share/licenses/xdg-desktop-portal-$instance/LICENSE"
    write "$prefix/share/xdg-desktop-portal/portals/$instance.portal" <<EOF
[portal]
DBusName=$bus
Interfaces=org.freedesktop.impl.portal.ScreenCast;org.freedesktop.impl.portal.Screenshot;
UseIn=$desktop
EOF
    write "$prefix/share/dbus-1/services/$bus.service" <<EOF
[D-BUS Service]
Name=$bus
Exec=$private/xdg-desktop-portal-$instance
SystemdService=xdg-desktop-portal-$instance.service
EOF
    write "$prefix/lib/systemd/user/xdg-desktop-portal-$instance.service" <<EOF
[Unit]
Description=Portal service ($desktop)
PartOf=graphical-session.target
After=graphical-session.target
ConditionEnvironment=WAYLAND_DISPLAY
[Service]
Type=dbus
BusName=$bus
ExecStart=$private/xdg-desktop-portal-$instance
Restart=on-failure
EOF
    ;;
integration-dms|integration-noctalia|integration-pearl)
    shell=${component#integration-}
    case $shell in
        dms) kind=dbus; command="$prefix/bin/dms run --session";;
        noctalia) kind=forking; command="$prefix/bin/noctalia --daemon";;
        pearl) kind=simple; command="$prefix/bin/pearl-git";;
    esac
    units=$prefix/lib/systemd/user
    unit=$instance-$shell.service
    write "$units/$unit" <<EOF
[Unit]
Description=$shell desktop for $desktop
PartOf=graphical-session.target
After=graphical-session.target
Requisite=graphical-session.target
Before=xdg-desktop-autostart.target
OnFailure=$instance-shell-failed.service
[Service]
Type=$kind
ExecCondition=$private/session-runtime.sh condition $shell
ExecStart=$command
Restart=on-failure
RestartSec=2
TimeoutStopSec=10
Slice=app-graphical.slice
EOF
    if [[ $shell == dms ]]; then printf 'BusName=org.freedesktop.Notifications\n' >> "$destination$units/$unit"; fi
    if [[ $shell == pearl ]]; then printf 'KillMode=process\n' >> "$destination$units/$unit"; fi
    install -d "$destination$units/graphical-session.target.wants"
    ln -s "../$unit" "$destination$units/graphical-session.target.wants/$unit"
    printf '[Service]\nExecCondition=%s/session-runtime.sh external-condition\n' "$private" | write "$units/$shell.service.d/60-$instance-selection.conf"
    if [[ $shell == pearl ]]; then
        # Suppress a separately enabled Git shell unit in this managed session.
        printf '[Service]\nExecCondition=%s/session-runtime.sh external-condition\n' "$private" | write "$units/pearl-git.service.d/60-$instance-selection.conf"
    fi
    if [[ $shell == noctalia ]]; then transform < "$root/packaging/noctalia/config.toml" | write "$prefix/share/$instance/noctalia/config.toml"; fi
    ;;
*) aq_die "Unknown Git desktop component: $component";;
esac
