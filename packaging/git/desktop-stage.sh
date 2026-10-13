#!/usr/bin/env bash
# Stage optional desktop components into an empty package root, never the host.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$root/packaging/components/common.sh"
case ${1:-} in git) desktop=Aqueous-Git;; intel-git) desktop=Aqueous-Intel-Git;; *) aq_die 'Expected git|intel-git COMPONENT';; esac
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
        -e "s/@INSTANCE@-(init|wm|shell-action|portal-picker)\b/aqueous-\1-$channel/g" \
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
    # Git sessions have no setup application; preserve stable runtime defaults.
    sed -i 's/^setup_command=.*/setup_command=/' "$destination$private/session-runtime.sh"
    # No bundled picker for DMS or shell-free sessions. An explicit dmenu
    # command in the portal config can provide one; never select a source here.
    sed -i -E \
        -e 's@dms\) exec .*;;@dms) fail "No screen-sharing chooser configured for this shell; configure chooser_cmd in the portal config.";;@' \
        -e 's@\*\) exec aqueous-portal-picker-'"$channel"';;@*) fail "No screen-sharing chooser configured for this shell; configure chooser_cmd in the portal config.";;@' \
        "$destination$private/session-runtime.sh"
    # Git Pearl ships suffixed binaries; retain "pearl" as the selection ID.
    sed -i -e 's/^pearl_binary=pearl$/pearl_binary=pearl-git/' \
        -e 's/^pearl_control=pearlctl$/pearl_control=pearlctl-git/' "$destination$private/session-runtime.sh"
    sed -i 's|/lib/pearl/pearl-capture-picker|/lib/pearl-git/pearl-capture-picker|g' "$destination$private/session-runtime.sh"
    # Preserve a separate Pearl Git portal identity after the Aqueous transform.
    sed -i -e 's/Pearl:/Pearl-Git:/g' \
        -e 's/xdg-desktop-portal-pearl\.service/xdg-desktop-portal-pearl-git.service/g' \
        "$destination$private/session-runtime.sh"
    # Applications activated through the user manager need the same toolchain
    # and instance marker as direct compositor children.
    sed -i '/^export AQUEOUS_SOCKET=/! s/AQUEOUS_SOCKET /AQUEOUS_SOCKET AQUEOUS_INSTANCE PATH LD_LIBRARY_PATH /g' "$destination$prefix/bin/aqueous-init-$channel"
    # Inherited stable packaging overrides must not retarget this desktop.
    sed -i '2a export AQUEOUS_SHARE_DIR="'"$prefix/share/$instance"'"\nexport AQUEOUS_SESSION_RUNTIME="'"$private/session-runtime.sh"'"\nexport AQUEOUS_SYSCONFDIR="'"$sysconf"'"\nexport AQUEOUS_UNIT_DIR="'"$prefix/lib/systemd/user"'"' "$destination$prefix/bin/aqueous-wm-$channel"
    # An explicit native init should not shut down legacy output services.
    sed -i '/^systemctl --user stop .*outputd.service/d' "$destination$prefix/bin/aqueous-wm-$channel"
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
    # Upstream dms.service already declares the notification BusName. A second
    # declaration fails unit loading, even when ExecCondition skips one shell.
    case $shell in
        dms) kind=exec; command="$prefix/bin/dms run --session";;
        noctalia) kind=forking; command="$prefix/bin/noctalia --daemon";;
        pearl) kind=simple; command="$private/bin/aqueous-activity-launch $prefix/bin/pearl-git";;
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
    if [[ $shell == dms || $shell == noctalia ]]; then
        printf 'KillMode=control-group\nSendSIGKILL=yes\n' >> "$destination$units/$unit"
    fi
    if [[ $shell == pearl ]]; then printf 'KillMode=process\n' >> "$destination$units/$unit"; fi
    printf '\n[Install]\nWantedBy=graphical-session.target\n' >> "$destination$units/$unit"
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
