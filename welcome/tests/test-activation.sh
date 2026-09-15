#!/usr/bin/env bash
# Native worker lifecycle with an isolated service-manager fixture.
set -euo pipefail
binary=$(realpath "${1:?Pass welcome binary}")
instance=${2:-aqueous}
base=$(mktemp -d)
trap 'rm -rf -- "$base"' EXIT
export HOME=$base/home XDG_CONFIG_HOME=$base/config XDG_STATE_HOME=$base/state XDG_RUNTIME_DIR=$base/run
export WAYLAND_DISPLAY=welcome-fixture AQUEOUS_NESTED=0 AQUEOUS_SESSION_RUNTIME=$base/no-runtime
case $instance in aqueous) export XDG_CURRENT_DESKTOP=Aqueous;; aqueous-git) export XDG_CURRENT_DESKTOP=Aqueous-Git;; aqueous-intel-git) export XDG_CURRENT_DESKTOP=Aqueous-Intel-Git;; *) exit 1;; esac
export PATH=$base/bin:$PATH FIXTURE_ROOT=$base FIXTURE_INSTANCE=$instance
mkdir -p "$base"/{home,bin,active,enabled} "$XDG_CONFIG_HOME/$instance" "$XDG_STATE_HOME/$instance" "$XDG_RUNTIME_DIR/$instance"
touch "$XDG_STATE_HOME/$instance/welcome.lock"
for executable in pearl pearl-git dms noctalia; do
 printf '#!/bin/sh\nexit 0\n' > "$base/bin/$executable"
 chmod +x "$base/bin/$executable"
done
cat > "$base/bin/systemctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == --user ]]; shift
printf '%s\n' "$*" >> "$FIXTURE_ROOT/calls"
case $1 in
 is-active)
  if [[ $3 == graphical-session.target ]]; then [[ ${FAIL_TARGET:-0} == 0 ]]; else [[ -f $FIXTURE_ROOT/active/$3 ]]; fi;;
 show-environment) printf 'WAYLAND_DISPLAY=%s\n' "${MANAGER_DISPLAY:-$WAYLAND_DISPLAY}";;
 daemon-reload) ;;
 show) printf '%s\n' "${LOAD_STATE:-loaded}";;
 enable)
  [[ ${FAIL_ENABLE:-0} == 0 ]] || exit 1
  touch "$FIXTURE_ROOT/enabled/$2";;
 stop) rm -f "$FIXTURE_ROOT/active/$2";;
 start)
  [[ $2 != "${FAIL_START:-}" ]] || exit 1
  [[ $2 != "${SKIP_START:-}" ]] || exit 0
  shell=${2#"$FIXTURE_INSTANCE-"}; shell=${shell%.service}
  jq -e --arg shell "$shell" '.shell==$shell' "$XDG_RUNTIME_DIR/$FIXTURE_INSTANCE/welcome-session.json" >/dev/null
  touch "$FIXTURE_ROOT/active/$2";;
 *) exit 97;;
esac
SH
chmod +x "$base/bin/systemctl"
reset() {
 rm -f "$base/active/"* "$base/enabled/"* "$base/calls"
 unset FAIL_TARGET FAIL_ENABLE FAIL_START SKIP_START MANAGER_DISPLAY LOAD_STATE
 printf 'version=1\nshell="%s"\n' "$2" > "$XDG_CONFIG_HOME/$instance/session.toml"
 jq -n --arg shell "$1" --arg display "$WAYLAND_DISPLAY" '{shell:$shell,display:$display}' > "$XDG_RUNTIME_DIR/$instance/welcome-session.json"
 [[ $1 == none ]] || touch "$base/active/$instance-$1.service"
 touch "$base/active/unrelated.service"
}
activate() { "$binary" --worker activate "$1" > "$base/events"; }
for old in none pearl dms noctalia; do
 for selected in none pearl dms noctalia; do
  reset "$old" "$selected"
  activate "$selected"
  jq -e 'select(.kind=="activated")' "$base/events" >/dev/null
  [[ $($binary --worker active-selection) == "$selected" ]]
  [[ -f $base/active/unrelated.service ]]
  if [[ $selected != none ]]; then
   [[ -f $base/enabled/$instance-$selected.service && -f $base/active/$instance-$selected.service ]]
  else ! grep -q '^enable ' "$base/calls"; fi
  if [[ $old != none && $old != "$selected" ]]; then [[ ! -f $base/active/$instance-$old.service ]]; fi
 done
done
printf 'PASS: %s enables the matching service and activates all 16 desktop transitions\n' "$instance"
for failure in failed skipped; do
 reset dms pearl
 if [[ $failure == failed ]]; then export FAIL_START=$instance-pearl.service; else export SKIP_START=$instance-pearl.service; fi
 if activate pearl; then exit 1; fi
 jq -e 'select(.kind=="error")' "$base/events" >/dev/null
 [[ $($binary --worker active-selection) == dms && -f $base/active/$instance-dms.service ]]
 [[ ! -f $base/active/$instance-pearl.service && $($binary --worker selection) == pearl ]]
done
for failure in enable target display missing stale nested foreign; do
 reset dms pearl
 case $failure in
  enable) export FAIL_ENABLE=1;; target) export FAIL_TARGET=1;; display) export MANAGER_DISPLAY=another-display;;
  missing) export LOAD_STATE=not-found;; stale) printf 'version=1\nshell="none"\n' > "$XDG_CONFIG_HOME/$instance/session.toml";;
  nested) export AQUEOUS_NESTED=1;; foreign) export XDG_CURRENT_DESKTOP=GNOME;;
 esac
 if activate pearl; then exit 1; fi
 [[ -f $base/active/$instance-dms.service ]]
 [[ ! -f $base/calls ]] || ! grep -Eq '^(stop|start) ' "$base/calls"
 export AQUEOUS_NESTED=0
done
printf 'PASS: startup recovery and failed prerequisites preserve the running desktop\n'
