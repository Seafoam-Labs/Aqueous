#!/usr/bin/env bash
# Native worker lifecycle with an isolated service-manager fixture.
set -euo pipefail
binary=$(realpath "${1:?Pass welcome binary}")
instance=${2:-aqueous}
base=$(mktemp -d)
trap 'rm -rf -- "$base"' EXIT
export HOME=$base/home XDG_CONFIG_HOME=$base/config XDG_STATE_HOME=$base/state XDG_RUNTIME_DIR=$base/run
export WAYLAND_DISPLAY=welcome-fixture AQUEOUS_NESTED=0 AQUEOUS_SESSION_RUNTIME=$base/no-runtime AQUEOUS_SHARE_DIR=$base/share
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
 show-environment) printf 'AQUEOUS_INSTANCE=%s\n' "${MANAGER_INSTANCE:-$FIXTURE_INSTANCE}"; printf 'WAYLAND_DISPLAY=%s\n' "${MANAGER_DISPLAY:-$WAYLAND_DISPLAY}";;
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

# Switching is a separate transaction: persistent selection and runtime both
# roll back, and shell-owned settings are never passed through setup/seeding.
export AQUEOUS_INSTANCE=$instance
case $instance in aqueous) export XDG_CURRENT_DESKTOP=Aqueous;; aqueous-git) export XDG_CURRENT_DESKTOP=Aqueous-Git;; aqueous-intel-git) export XDG_CURRENT_DESKTOP=Aqueous-Intel-Git;; esac
switch_shell() {
 if [[ -n ${SWITCH_CLI:-} ]]; then
  "$SWITCH_CLI" shell switch "$1" --json > "$base/events"
 else "$binary" --worker switch-shell "$1" --json > "$base/events"; fi
}
if [[ -n ${SWITCH_CLI:-} ]]; then
 ln -s "$binary" "$base/bin/aqueous-welcome-${instance#aqueous-}"
fi
if [[ $instance == aqueous ]]; then
 reset dms dms
 if switch_shell pearl; then exit 1; fi
 jq -e '.ok == false' "$base/events" >/dev/null
 [[ ! -e $base/calls ]]
 exit 0
fi
for shell in pearl dms noctalia; do
 mkdir -p "$XDG_CONFIG_HOME/$shell/nested"
 printf 'custom settings for %s\n' "$shell" > "$XDG_CONFIG_HOME/$shell/nested/settings"
 ln -s nested/settings "$XDG_CONFIG_HOME/$shell/settings-link"
done
mkdir -p "$XDG_CONFIG_HOME/quickshell/dms" "$XDG_CONFIG_HOME/aqueous"
printf 'custom DMS configuration\n' > "$XDG_CONFIG_HOME/quickshell/dms/settings.json"
printf 'stable sentinel\n' > "$XDG_CONFIG_HOME/aqueous/session.toml"
cp -a "$XDG_CONFIG_HOME" "$base/config-before"
check_preserved() {
 for shell in pearl dms noctalia quickshell aqueous; do
  diff -r --no-dereference "$base/config-before/$shell" "$XDG_CONFIG_HOME/$shell"
 done
}
for old in pearl dms noctalia; do
 for selected in pearl dms noctalia; do
  reset "$old" "$old"
  cp "$XDG_CONFIG_HOME/$instance/session.toml" "$base/selection-before"
  cp "$XDG_RUNTIME_DIR/$instance/welcome-session.json" "$base/runtime-before"
  switch_shell "$selected"
  jq -e --arg shell "$selected" '.ok and .shell == $shell' "$base/events" >/dev/null
  [[ $($binary --worker selection) == "$selected" && $($binary --worker active-selection) == "$selected" ]]
  [[ -f $base/active/$instance-$selected.service && -f $base/active/unrelated.service ]]
  if [[ $old == "$selected" ]]; then
   ! grep -Eq '^(stop|start|enable) ' "$base/calls"
   cmp "$base/selection-before" "$XDG_CONFIG_HOME/$instance/session.toml"
   cmp "$base/runtime-before" "$XDG_RUNTIME_DIR/$instance/welcome-session.json"
  else [[ ! -f $base/active/$instance-$old.service ]]; fi
  check_preserved
 done
done
for command in bash rm touch jq; do ln -s "$(command -v "$command")" "$base/bin/$command"; done
fixture_path=$PATH
for failure in failed skipped target display instance missing masked bad-setting error nested foreign snapshot lock executable invalid; do
 reset dms dms
 cp "$XDG_CONFIG_HOME/$instance/session.toml" "$base/selection-before"
 cp "$XDG_RUNTIME_DIR/$instance/welcome-session.json" "$base/runtime-before"
 target=pearl
 case $failure in
  failed) export FAIL_START=$instance-pearl.service;;
  skipped) export SKIP_START=$instance-pearl.service;;
  target) export FAIL_TARGET=1;; display) export MANAGER_DISPLAY=other-display;;
  instance) export MANAGER_INSTANCE=aqueous;; missing) export LOAD_STATE=not-found;;
  masked|bad-setting|error) export LOAD_STATE=$failure;;
  nested) export AQUEOUS_NESTED=1;; foreign) export XDG_CURRENT_DESKTOP=Aqueous;;
  snapshot) rm "$XDG_RUNTIME_DIR/$instance/welcome-session.json";;
  lock) exec 9> "$XDG_STATE_HOME/$instance/welcome.lock"; flock -n 9;;
  executable) chmod -x "$base/bin/pearl-git"; export PATH=$base/bin;; invalid) target=none;;
 esac
 if switch_shell "$target"; then echo "Unexpected switch success: $failure" >&2; exit 1; fi
 export PATH=$fixture_path
 jq -e '.ok == false' "$base/events" >/dev/null
 case $failure in
  missing|masked|bad-setting|error)
   jq -e --arg unit "$instance-pearl.service" --arg state "$LOAD_STATE" \
    '.message | contains($unit) and contains("LoadState=" + $state) and (contains("install aqueous-shell") | not)' "$base/events" >/dev/null;;
 esac
 [[ -f $base/active/$instance-dms.service && ! -f $base/active/$instance-pearl.service ]]
 cmp "$base/selection-before" "$XDG_CONFIG_HOME/$instance/session.toml"
 if [[ $failure != snapshot ]]; then cmp "$base/runtime-before" "$XDG_RUNTIME_DIR/$instance/welcome-session.json"; fi
 if [[ $failure != failed && $failure != skipped ]]; then
  [[ ! -f $base/calls ]] || ! grep -Eq '^(stop|start) ' "$base/calls"
 fi
 check_preserved
 unset MANAGER_INSTANCE
 export AQUEOUS_NESTED=0
 case $instance in aqueous-git) export XDG_CURRENT_DESKTOP=Aqueous-Git;; aqueous-intel-git) export XDG_CURRENT_DESKTOP=Aqueous-Intel-Git;; esac
 chmod +x "$base/bin/pearl-git"
 if [[ $failure == lock ]]; then flock -u 9; exec 9>&-; fi
done
# A successful switch must not create defaults even when a shell has no config.
reset dms dms
mkdir -p "$base/share/noctalia"
printf 'default settings\n' > "$base/share/noctalia/config.toml"
export AQUEOUS_SHARE_DIR=$base/share
switch_shell noctalia
[[ ! -e $XDG_CONFIG_HOME/noctalia/config.toml ]]
check_preserved
printf 'PASS: %s shell switches persist, roll back, enforce session isolation, and preserve shell configurations\n' "$instance"
