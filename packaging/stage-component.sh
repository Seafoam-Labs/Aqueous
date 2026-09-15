#!/usr/bin/env bash
# Stage a single component. Legacy staging entry points retain their behavior.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/packaging/components/common.sh"
[[ $# == 1 ]] || aq_die 'Usage: DESTDIR=/private/root stage-component.sh COMPONENT'
component=$1
aq_component "$component"
destination=${DESTDIR:?Set DESTDIR to an empty private staging root}
prefix=${PREFIX:-/usr}
sysconfdir=${SYSCONFDIR:-/etc}
for path in "$prefix" "$sysconfdir"; do
    [[ $path =~ ^/[a-zA-Z0-9_./+-]+$ && /$path/ != */../* ]] || aq_die 'Use absolute, shell-safe PREFIX and SYSCONFDIR paths'
done
destination=$(realpath -m -s -- "$destination")
aq_empty_root "$destination"
copy() { install -Dm"${3:-644}" -- "$1" "$destination$2"; }
write() { install -d -- "$destination$(dirname -- "$1")"; cat > "$destination$1"; chmod "${2:-644}" "$destination$1"; }
relocate() { sed -e "s|/usr/|$prefix/|g" -e "s|/etc/|$sysconfdir/|g" "$1"; }
link() { install -d -- "$destination$(dirname -- "$1")"; ln -s -- "$2" "$destination$1"; }
tree() {
    local source=$1 path=$2 entry
    [[ -d $source ]] || aq_die "Missing tree: $source"
    [[ -z $(find "$source" -type l -print -quit) ]] || aq_die "Unexpected input symlink in $source"
    while IFS= read -r -d '' entry; do copy "$entry" "$path/${entry#"$source/"}"; done < <(find "$source" -type f -print0 | sort -z)
}
case $component in
core)
    compositor=${AQUEOUS_COMPOSITOR_DIST:-$root/compositor/zig-out}
    aq_policy "$compositor/share/aqueous/build-policy.json"
    copy "$compositor/bin/aqueous" "$prefix/bin/aqueous" 755
    copy "$compositor/lib/aqueous/libwlroots-0.20.so" "$prefix/lib/aqueous/libwlroots-0.20.so" 755
    AQUEOUSCTL_BINARY="$compositor/bin/aqueousctl" DESTDIR="$destination" PREFIX="$prefix" \
        bash "$root/settingsApplication/packaging/install-config.sh"
    for name in aqueous aqueousctl; do copy "$compositor/share/man/man1/$name.1" "$prefix/share/man/man1/$name.1"; done
    tree "$compositor/share/aqueous-protocols" "$prefix/share/aqueous-protocols"
    sed "s|^prefix=.*|prefix=$prefix|" "$compositor/share/pkgconfig/aqueous-protocols.pc" | write "$prefix/share/pkgconfig/aqueous-protocols.pc"
    tree "$root/compositor/LICENSES" "$prefix/share/licenses/aqueous-core/compositor"
    copy "$root/README.md" "$prefix/share/doc/aqueous-core/README.md"
    copy "$compositor/share/aqueous/build-policy.json" "$prefix/share/aqueous/build-policy.json"
    ;;
session)
    relocate "$root/packaging/components/session-runtime.sh" | sed "s|AQUEOUS_SYSCONFDIR:-/etc}|AQUEOUS_SYSCONFDIR:-$sysconfdir}|" | write "$prefix/lib/aqueous/session-runtime.sh" 755
    # Replace only the legacy selection block in the staged copy.
    relocate "$root/packaging/aqueous-init" | awk -v runtime="$prefix/lib/aqueous/session-runtime.sh" '
        !done && /^if \[ "\$\{AQUEOUS_NESTED:-0\}/ {
            print "if [ \"${AQUEOUS_NESTED:-0}\" != 1 ]; then"
            print "    " runtime " prepare-session || exit 1"
            print "fi"; skipping=1; done=1; next
        }
        skipping { if ($0 == "fi") skipping=0; next }
        { print }
    ' | write "$prefix/bin/aqueous-init" 755
    relocate "$root/packaging/aqueous-wm.sh" | write "$prefix/bin/aqueous-wm" 755
    printf '#!/bin/sh\nexec "%s/lib/aqueous/session-runtime.sh" action "$@"\n' "$prefix" | write "$prefix/bin/aqueous-shell-action" 755
    relocate "$root/aqueous.desktop" | write "$prefix/share/wayland-sessions/aqueous.desktop"
    while IFS='|' read -r source path; do relocate "$root/$source" | write "$path"; done <<EOF
packaging/uwsm/env-aqueous|$sysconfdir/xdg/uwsm/env-aqueous
packaging/menus/aqueous-applications.menu|$sysconfdir/xdg/menus/aqueous-applications.menu
packaging/aqueous-portals.conf|$prefix/share/xdg-desktop-portal/aqueous-portals.conf
packaging/aqueous-session.target|$prefix/lib/systemd/user/aqueous-session.target
packaging/aqueous.tmpfiles|$prefix/lib/tmpfiles.d/aqueous.conf
packaging/ghostty/config.ghostty|$prefix/share/aqueous/ghostty/config.ghostty
packaging/greetd/config.toml.example|$prefix/share/doc/aqueous-session/greetd-config.toml.example
EOF
    tree "$root/packaging/wallpapers" "$prefix/share/aqueous/wallpapers"
    for path in "$prefix/share/aqueous/outputs.toml" "$sysconfdir/xdg/aqueous/outputs.toml"; do copy "$root/outputs.toml" "$path"; done
    # Package defaults only; never parse or edit a user's compositor TOML here.
    awk '
        /^\[actions\]$/ {
            print; print "toggle_start_menu = \"aqueous-shell-action launcher\""
            print "screenshot = \"aqueous-shell-action screenshot\""
            print "lock_screen = \"aqueous-shell-action lock\""; actions=1; next
        }
        /^\[/ { actions=0 }
        actions && /^(toggle_start_menu|screenshot|lock_screen)[[:space:]]*=/ { next }
        { gsub(/spawn:dms screenshot region|spawn:noctalia msg screenshot-region/, "spawn:aqueous-shell-action screenshot"); print }
    ' "$root/wm.toml" | write "$prefix/share/aqueous/wm.toml"
    copy "$destination$prefix/share/aqueous/wm.toml" "$sysconfdir/xdg/aqueous/wm.toml"
    printf '[screencast]\nchooser_type=dmenu\nchooser_cmd=%s/bin/aqueous-shell-action chooser\n' "$prefix" | write "$sysconfdir/xdg/xdg-desktop-portal-aqueous/config"
    write "$prefix/lib/systemd/user/aqueous-shell-failed.service" <<EOF
[Unit]
Description=Report failed Aqueous shell startup
PartOf=graphical-session.target
[Service]
Type=oneshot
ExecStart=$prefix/lib/aqueous/session-runtime.sh recover
EOF
    ;;
welcome)
    copy "${AQUEOUS_WELCOME_BINARY:-$root/welcome/zig-out/bin/aqueous-welcome}" "$prefix/bin/aqueous-welcome" 755
    relocate "$root/packaging/aqueous-welcome.desktop" | write "$prefix/share/applications/org.aqueous.Welcome.desktop"
    relocate "$root/packaging/aqueous-welcome-autostart.desktop" | write "$sysconfdir/xdg/autostart/org.aqueous.Welcome.desktop"
    ;;
portal)
    copy "${AQUEOUS_PORTAL_BINARY:-$root/dist/aqueous-portal-dist/usr/lib/aqueous/xdg-desktop-portal-aqueous}" "$prefix/lib/aqueous/xdg-desktop-portal-aqueous" 755
    while IFS='|' read -r source path; do relocate "$root/packaging/portal/$source" | write "$prefix/$path"; done <<'EOF'
aqueous.portal|share/xdg-desktop-portal/portals/aqueous.portal
org.freedesktop.impl.portal.desktop.aqueous.service|share/dbus-1/services/org.freedesktop.impl.portal.desktop.aqueous.service
xdg-desktop-portal-aqueous.service|lib/systemd/user/xdg-desktop-portal-aqueous.service
EOF
    copy "${AQUEOUS_PORTAL_LICENSE:-$root/dist/xdg-desktop-portal-wlr-0.8.4/LICENSE}" "$prefix/share/licenses/xdg-desktop-portal-aqueous/LICENSE"
    ;;
integration-*)
    shell=${component#integration-}
    case $shell in
        dms) kind=dbus; command="$prefix/bin/dms run --session" ;;
        noctalia) kind=forking; command="$prefix/bin/noctalia --daemon" ;;
        pearl) kind=simple; command="$prefix/bin/pearl" ;;
    esac
    units=$prefix/lib/systemd/user
    unit=aqueous-$shell.service
    write "$units/$unit" <<EOF
[Unit]
Description=$shell desktop for Aqueous
PartOf=graphical-session.target
After=graphical-session.target
Requisite=graphical-session.target
Before=xdg-desktop-autostart.target
OnFailure=aqueous-shell-failed.service
[Service]
Type=$kind
ExecCondition=$prefix/lib/aqueous/session-runtime.sh condition $shell
ExecStart=$command
Restart=on-failure
RestartSec=2
TimeoutStopSec=10
Slice=app-graphical.slice
EOF
    case $shell in
        dms) printf 'BusName=org.freedesktop.Notifications\n' >> "$destination$units/$unit" ;;
        pearl) printf '# The locker must survive a shell restart.\nKillMode=process\n' >> "$destination$units/$unit" ;;
    esac
    printf '\n[Install]\nWantedBy=graphical-session.target\n' >> "$destination$units/$unit"
    link "$units/graphical-session.target.wants/$unit" "../$unit"
    printf '[Service]\nExecCondition=%s/lib/aqueous/session-runtime.sh external-condition\n' "$prefix" | write "$units/$shell.service.d/50-aqueous-selection.conf"
    if [[ $shell == noctalia ]]; then relocate "$root/packaging/noctalia/config.toml" | write "$prefix/share/aqueous/noctalia/config.toml"; fi
    if [[ $shell == dms ]]; then
        copy "${AQUEOUS_PORTAL_CHOOSER_BINARY:-$root/packaging/portal/bridge/zig-out/bin/aqueous-dms-portal-chooser}" "$prefix/lib/aqueous/aqueous-dms-portal-chooser" 755
        tree "$root/packaging/portal/dms" "$prefix/share/aqueous/dms-plugins/aqueousPortal"
        tree "$root/settingsApplication/packaging/dms-appearance" "$prefix/share/aqueous/dms-plugins/aqueousSettingsAppearance"
        for name in aqueousPortal aqueousSettingsAppearance; do link "$sysconfdir/xdg/quickshell/dms-plugins/$name" "$prefix/share/aqueous/dms-plugins/$name"; done
    fi
    ;;
esac
