#!/bin/sh
# Shared, relocatable staging for GTK welcome and the shell-neutral Arch session.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination=${DESTDIR:-}
prefix=${PREFIX:-/usr}
sysconfdir=${SYSCONFDIR:-/etc}
binary=${AQUEOUS_WELCOME_BINARY:-$root/welcome/zig-out/bin/aqueous-welcome}
install -Dm755 "$binary" "$destination$prefix/bin/aqueous-welcome"
install -Dm644 "$root/packaging/aqueous-welcome.desktop" "$destination$prefix/share/applications/org.aqueous.Welcome.desktop"
install -Dm644 "$root/packaging/aqueous-welcome-autostart.desktop" "$destination$sysconfdir/xdg/autostart/org.aqueous.Welcome.desktop"
install -Dm644 "$root/packaging/noctalia/config.toml" "$destination$prefix/share/aqueous/noctalia/config.toml"
units="$destination$prefix/lib/systemd/user"
install -d "$units/graphical-session.target.wants" "$destination$prefix/bin"
for shell in pearl dms noctalia; do
    unit="aqueous-$shell.service"
    case "$shell" in
        pearl) type=simple; command="$prefix/bin/pearl" ;;
        dms) type=dbus; command="$prefix/bin/dms run --session" ;;
        noctalia) type=forking; command="$prefix/bin/noctalia --daemon" ;;
    esac
    cat > "$units/$unit" <<EOF
[Unit]
Description=$shell desktop for Aqueous
PartOf=graphical-session.target
After=graphical-session.target
Requisite=graphical-session.target
Before=xdg-desktop-autostart.target
OnFailure=aqueous-shell-failed.service

[Service]
Type=$type
ExecCondition=$prefix/bin/aqueous-welcome --worker condition $shell
ExecStart=$command
Restart=on-failure
RestartSec=2
TimeoutStopSec=10
Slice=app-graphical.slice
EOF
    if [ "$shell" = dms ]; then
        printf '%s\n' 'BusName=org.freedesktop.Notifications' >> "$units/$unit"
    fi
    if [ "$shell" = pearl ]; then
        printf '%s\n' '# The locker must survive a shell restart.' 'KillMode=process' >> "$units/$unit"
    fi
    printf '\n[Install]\nWantedBy=graphical-session.target\n' >> "$units/$unit"
    ln -sf "../$unit" "$units/graphical-session.target.wants/$unit"
    # Package-owned global enablement is replaced by conditional Aqueous units.
    rm -f "$units/graphical-session.target.wants/$shell.service"
    install -d "$units/$shell.service.d"
    cat > "$units/$shell.service.d/50-aqueous-selection.conf" <<EOF
[Service]
ExecCondition=$prefix/bin/aqueous-welcome --worker external-condition
EOF
done
cat > "$units/aqueous-shell-failed.service" <<EOF
[Unit]
Description=Recover failed Aqueous shell startup
PartOf=graphical-session.target

[Service]
Type=exec
ExecStart=$prefix/bin/aqueous-welcome --message "Your desktop shell failed to start. Review setup or choose another shell."
EOF
cat > "$destination$prefix/bin/aqueous-shell-action" <<EOF
#!/bin/sh
exec '$prefix/bin/aqueous-welcome' --worker action "\$@"
EOF
chmod 755 "$destination$prefix/bin/aqueous-shell-action"
install -d "$destination$sysconfdir/xdg/xdg-desktop-portal-aqueous"
cat > "$destination$sysconfdir/xdg/xdg-desktop-portal-aqueous/config" <<EOF
[screencast]
chooser_type=dmenu
chooser_cmd=$prefix/bin/aqueous-shell-action chooser
EOF
# Only package defaults are transformed. Existing user files go through the
# canonical helper and the reviewed setup transaction.
install -d "$destination$prefix/share/aqueous" "$destination$sysconfdir/xdg/aqueous"
awk '
    /^\[actions\]$/ {
        print; print "toggle_start_menu = \"aqueous-shell-action launcher\""
        print "screenshot = \"aqueous-shell-action screenshot\""
        print "lock_screen = \"aqueous-shell-action lock\""; actions=1; next
    }
    /^\[/ { actions=0 }
    actions && /^(toggle_start_menu|screenshot|lock_screen)[[:space:]]*=/ { next }
    /^\[keybinds.custom\]$/ { print; print "\"Super+Shift+F1\" = \"spawn:aqueous-welcome\""; next }
    { gsub(/spawn:dms screenshot region|spawn:noctalia msg screenshot-region/, "spawn:aqueous-shell-action screenshot"); print }
' "$root/wm.toml" > "$destination$prefix/share/aqueous/wm.toml"
install -m644 "$destination$prefix/share/aqueous/wm.toml" "$destination$sysconfdir/xdg/aqueous/wm.toml"
