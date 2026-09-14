#!/usr/bin/env bash
# End-to-end native worker tests. Fixtures never touch host packages or services.
set -euo pipefail
binary=$(realpath "${1:?Pass aqueous-welcome executable}")
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
base=$(mktemp -d)
trap 'rm -rf -- "$base"' EXIT
export HOME=$base/home XDG_CONFIG_HOME=$base/config XDG_STATE_HOME=$base/state XDG_RUNTIME_DIR=$base/run
export XDG_CURRENT_DESKTOP=Aqueous WAYLAND_DISPLAY=private-test AQUEOUS_NESTED=0
export AQUEOUS_SESSION_RUNTIME=$base/no-runtime AQUEOUS_SHARE_DIR=$base/share
export PATH=$base/bin:$PATH FIXTURE_ROOT=$base
mkdir -p "$base"/{home,config,state,run,bin,share/noctalia}
cat > "$base/bin/aqueous-config" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >> "$FIXTURE_ROOT/helper-log"
case $1 in
 snapshot) cat "$FIXTURE_ROOT/snapshot";;
 validate|apply)
  cat > "$FIXTURE_ROOT/request"
  if [[ $1 == apply ]]; then cp "$FIXTURE_ROOT/request" "$FIXTURE_ROOT/apply-request"; fi
  jq -e '.protocol == 1 and .expected_generation == "g"' "$FIXTURE_ROOT/request" >/dev/null
  if [[ $1 == validate ]]; then
   count=0; [[ ! -f $FIXTURE_ROOT/validations ]] || read -r count < "$FIXTURE_ROOT/validations"
   printf '%s\n' "$((count+1))" > "$FIXTURE_ROOT/validations"
   if [[ ${SCENARIO:-} == stale && $count -gt 0 ]]; then printf '{"ok":false,"message":"stale generation"}\n'; exit; fi
  fi
  cat "$FIXTURE_ROOT/snapshot";;
esac
SH
cat > "$base/bin/shelly" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
frame() {
 local data index
 data="[JSON]$(printf '%s' "$1" | base64 -w0)[/JSON]"
 for ((index=0;index<${#data};index+=9)); do printf '%s' "${data:index:9}"; done
 printf '\n'
}
answer() { local line; IFS= read -r line; line=${line#'[JSON]'}; line=${line%'[/JSON]'}; printf '%s' "$line" | base64 -d; }
if [[ $1 == list ]]; then
 if [[ -f $FIXTURE_ROOT/packages ]]; then cat "$FIXTURE_ROOT/packages"; else printf '[]\n'; fi
 exit
fi
printf '%s\n' "$*" >> "$FIXTURE_ROOT/install-log"
case ${SCENARIO:-normal} in
 failure) exit 1;;
 no-done) frame '{"$kind":"alpm.progress","Percent":100}'; exit;;
 cancelled) frame '{"$kind":"alpm.info","EventType":"TransactionCancelled"}'; exit;;
 malformed) printf '[JSON]not base64[/JSON]\n'; exit;;
 commit|disconnect)
  frame '{"$kind":"alpm.info","Message":"Committing"}'
  sleep .2
  touch "$FIXTURE_ROOT/committed"
  frame '{"$kind":"alpm.info","EventType":"TransactionDone"}'
  exit;;
esac
exec 3<> /dev/tty
case " $(stty -a <&3) " in *' -echo '*) ;; *) exit 91;; esac
if [[ ${SCENARIO:-} == echo ]]; then stty echo <&3; fi
for attempt in 1 2; do
 printf '[sudo] password for fixture: ' >&3
 IFS= read -r secret <&3
 [[ $secret == fixture-secret ]] || exit 92
 unset secret
 printf '\n' >&3
done
exec 3>&-
for id in 1 2; do
 frame "{\"\$kind\":\"q.optdeps\",\"QuestionId\":\"$id\",\"Options\":[{\"Index\":7},{\"Index\":19,\"IsInstalled\":true},{\"Index\":42}]}"
 answer | jq -e --arg id "$id" '. == {"$kind":"a.optdeps",QuestionId:$id,SelectedIndices:[7,42]}' >/dev/null
done
frame '{"$kind":"q.provider","QuestionId":"3","Options":[{"Index":7,"Name":"first"},{"Index":42,"Name":"second"}]}'
answer | jq -e '. == {"$kind":"a.provider",QuestionId:"3",SelectedIndex:42}' >/dev/null
frame '{"$kind":"q.transaction","QuestionId":"4","QuestionText":"Install packages?","Packages":[{"Name":"test"}]}'
answer | jq -e '. == {"$kind":"a.transaction",QuestionId:"4",Accept:true}' >/dev/null
head -c 100000 /dev/zero >&2
jq -n --args '$ARGS.positional | map(select(. != "--ui-mode") | {Name:.,Id:.})' -- "${@:3}" > "$FIXTURE_ROOT/packages"
frame '{"$kind":"alpm.info","EventType":"TransactionDone","Message":"Installed"}'
SH
chmod +x "$base/bin/aqueous-config" "$base/bin/shelly"
for shell in pearl dms noctalia; do printf '#!/bin/sh\nexit 0\n' > "$base/bin/$shell"; chmod +x "$base/bin/$shell"; done
reset() {
 rm -rf "$base/config" "$base/state" "$base/run"
 mkdir -p "$base/config/aqueous" "$base/state" "$base/run"
 rm -f "$base"/{install-log,helper-log,validations,packages,committed,events,request,apply-request}
 printf 'version=1\nshell="dms"\n' > "$base/config/aqueous/session.toml"
 cat > "$base/snapshot" <<'JSON'
{"generation":"g","fields":[],"raw_files":{},"capabilities":["shell_none","schema_fields","validate","generation_check","stdin_requests","apply_result_v1","operation_receipts_v1","candidate_impact_v1","recoverable_commit_v1"]}
JSON
 export SCENARIO=normal
}
worker() {
 local selected=$1 event kind id pid output input original_output original_input status=0 disconnected=false
 coproc WORKER { timeout 20 "$binary" --worker setup "$selected" "${@:2}"; }
 pid=$WORKER_PID
 exec {output}<&"${WORKER[0]}" {input}>&"${WORKER[1]}"
 original_output=${WORKER[0]}; original_input=${WORKER[1]}
 exec {original_output}<&- {original_input}>&-
 while IFS= read -r -u "$output" event; do
  printf '%s\n' "$event" >> "$base/events"
  kind=$(jq -r .kind <<< "$event")
  id=$(jq -r '.id // ""' <<< "$event")
  case $kind in
   review)
    if [[ ${SCENARIO:-} == decline ]]; then printf '{"accept":false}\n' >&"$input"
    else printf '{"accept":true}\n' >&"$input"; fi;;
   password) jq -cn --arg id "$id" '{id:$id,password:"fixture-secret"}' >&"$input";;
   question)
    if [[ ${SCENARIO:-} == stale-response ]]; then id=stale; fi
    jq -cn --arg id "$id" '{id:$id,accept:true,choice:42}' >&"$input";;
   progress)
    if [[ $SCENARIO == commit && $(jq -r .message <<< "$event") == Committing ]]; then printf '{"cancel":true}\n' >&"$input"; fi;;
  esac
  if [[ $SCENARIO == disconnect && $kind == progress && $(jq -r .message <<< "$event") == Committing ]]; then
   exec {output}<&- {input}>&-
   disconnected=true
   break
  fi
 done
 if ! $disconnected; then exec {output}<&- {input}>&-; fi
 wait "$pid" || status=$?
 [[ $status != 124 ]] || { cat "$base/events" >&2; printf 'Worker timed out\n' >&2; exit 1; }
 return "$status"
}
reset
worker none
[[ ! -f $base/install-log && -f $base/state/aqueous/welcome-v1 ]]
[[ $($binary --worker selection) == none ]]
grep -q 'Hidden=true' "$base/config/autostart/org.aqueous.Welcome.desktop"
printf 'Nothing completes without Shelly: passed\n'
reset
worker pearl
[[ $(jq -s '[.[]|select(.kind=="password")]|length' "$base/events") == 2 ]]
! grep -q fixture-secret "$base/events" "$base/state/aqueous/welcome-operation.json"
[[ $($binary --worker selection) == pearl && $($binary --worker active-selection) == dms ]]
grep -q 'install standard pearl --ui-mode' "$base/install-log"
[[ $(cat "$base/validations") == 2 ]]
printf 'Password terminal, fragmented questions, optional dependencies and active-session preservation: passed\n'
for scenario in failure no-done cancelled malformed commit disconnect echo stale stale-response decline; do
 reset; export SCENARIO=$scenario
 if worker pearl; then printf 'Unexpected success: %s\n' "$scenario" >&2; exit 1; fi
 [[ $($binary --worker selection) == dms && ! -f $base/state/aqueous/welcome-v1 ]]
 [[ $scenario != commit && $scenario != disconnect || -f $base/committed ]]
done
printf 'Failed, cancelled, stale and malformed transactions preserve configuration: passed\n'
# All 16 transitions keep the old runtime choice until preparation at next login.
reset
printf '[bar]\n' > "$base/share/noctalia/config.toml"
for old in pearl dms noctalia none; do
 for new in pearl dms noctalia none; do
  printf 'version=1\nshell="%s"\n' "$old" > "$base/config/aqueous/session.toml"
  "$binary" --worker prepare-session
  printf 'version=1\nshell="%s"\n' "$new" > "$base/config/aqueous/session.toml"
  [[ $($binary --worker active-selection) == "$old" ]]
  "$binary" --worker condition "$old"
  "$binary" --worker prepare-session
  [[ $($binary --worker active-selection) == "$new" ]]
 done
done
printf '# custom\n' > "$base/config/noctalia/config.toml"
printf 'version=1\nshell="noctalia"\n' > "$base/config/aqueous/session.toml"
"$binary" --worker prepare-session
grep -q '# custom' "$base/config/noctalia/config.toml"
if "$binary" --worker external-condition; then exit 1; fi
XDG_CURRENT_DESKTOP=GNOME "$binary" --worker external-condition
if AQUEOUS_NESTED=1 "$binary" --worker condition noctalia; then exit 1; fi
printf 'Legacy session transitions, conditions and Noctalia preservation: passed\n'
# Load journals in the exact format written by the removed Python worker.
reset
before=$(base64 -w0 "$base/config/aqueous/session.toml")
printf 'version=1\nshell="pearl"\n' > "$base/config/aqueous/session.toml"
after=$(base64 -w0 "$base/config/aqueous/session.toml")
mkdir -p "$base/state/aqueous"
jq -n --arg path "$base/config/aqueous/session.toml" --arg before "$before" --arg after "$after" \
 '{version:1,id:"legacy",phase:"configuring",files:[{path:$path,before:$before,after:$after}]}' > "$base/journal"
cp "$base/journal" "$base/state/aqueous/welcome-operation.json"
export SCENARIO=decline
if worker none; then exit 1; fi
[[ $($binary --worker selection) == dms ]]
cp "$base/journal" "$base/state/aqueous/welcome-operation.json"
printf 'version=1\nshell="noctalia"\n' > "$base/config/aqueous/session.toml"
if worker none; then exit 1; fi
[[ $($binary --worker selection) == noctalia ]]
grep -q 'Configuration changed since interrupted setup' "$base/events"
printf 'Legacy journal recovery and concurrent-edit refusal: passed\n'
reset
mkdir -p "$base/config/xdg-desktop-portal-aqueous"
printf '# custom comment\n[screencast]\nmax_fps=30\nchooser_cmd=noctalia dmenu -p "Select a source to share:"\n[other]\nvalue=keep\n' > "$base/config/xdg-desktop-portal-aqueous/Aqueous"
worker none
grep -q '# custom comment' "$base/config/xdg-desktop-portal-aqueous/Aqueous"
grep -q 'chooser_cmd=aqueous-shell-action chooser' "$base/config/xdg-desktop-portal-aqueous/Aqueous"
grep -q 'value=keep' "$base/config/xdg-desktop-portal-aqueous/Aqueous"
printf '[screencast]\nchooser_cmd=my-custom-picker\n' > "$base/config/xdg-desktop-portal-aqueous/Aqueous"
worker none
grep -q 'chooser_cmd=my-custom-picker' "$base/config/xdg-desktop-portal-aqueous/Aqueous"
printf '[DEFAULT]\nchooser_cmd=inherited-custom-picker\n[screencast]\nmax_fps=30\n' > "$base/config/xdg-desktop-portal-aqueous/Aqueous"
worker none
grep -q 'chooser_cmd=inherited-custom-picker' "$base/config/xdg-desktop-portal-aqueous/Aqueous"
! grep -q 'aqueous-shell-action chooser' "$base/config/xdg-desktop-portal-aqueous/Aqueous"
printf 'Portal comments, unrelated sections and custom overrides: passed\n'

reset
mkdir -p "$base/config/autostart"
printf '[Desktop Entry]\nExec=dms run --session\n' > "$base/config/autostart/custom.desktop"
if worker none; then exit 1; fi
[[ ! -f $base/helper-log && ! -f $base/state/aqueous/welcome-v1 ]]
printf 'OnlyShowIn=GNOME;\n' >> "$base/config/autostart/custom.desktop"
worker none
printf 'Custom startup conflict detection and desktop scoping: passed\n'

reset
# Recognized commands go through the helper, with canonical sources journaled.
jq '.fields=[{id:"actions.screenshot",value:"dms screenshot region"}]' "$base/snapshot" > "$base/snapshot-next"
mv "$base/snapshot-next" "$base/snapshot"
worker none
jq -e '.changes == [{id:"actions.screenshot",value:"aqueous-shell-action screenshot"}] and (.backup_dir|contains("welcome-backups"))' "$base/apply-request" >/dev/null
jq -e '.canonical == {before:{},after:{}}' "$base/state/aqueous/welcome-operation.json" >/dev/null

reset
mkdir -p "$base/state/aqueous"
jq '.raw_files={wm:"after"}' "$base/snapshot" > "$base/snapshot-next"
mv "$base/snapshot-next" "$base/snapshot"
printf '{"version":1,"id":"legacy","phase":"configuring","files":[],"canonical":{"before":{"wm":"before"},"after":{"wm":"after"}}}\n' > "$base/state/aqueous/welcome-operation.json"
export SCENARIO=decline
if worker none; then exit 1; fi
jq -e '.raw_files == {wm:"before"} and .expected_generation == "g"' "$base/apply-request" >/dev/null
printf 'Canonical edits and interrupted helper recovery use aqueous-config: passed\n'

reset
mkdir -p "$base/state/aqueous" "$base/outside"
printf 'outside\n' > "$base/outside/file"
ln -s "$base/outside" "$base/config/link"
jq -n --arg path "$base/config/link/file" --arg after "$(base64 -w0 "$base/outside/file")" \
 '{version:1,id:"unsafe",phase:"configuring",files:[{path:$path,before:null,after:$after}]}' > "$base/state/aqueous/welcome-operation.json"
if worker none; then exit 1; fi
[[ $(cat "$base/outside/file") == outside ]]
printf 'Recovery refuses symlink traversal: passed\n'

reset
export AQUEOUS_SESSION_RUNTIME=$repo/packaging/components/session-runtime.sh
export AQUEOUS_SYSCONFDIR=$base/etc
worker pearl
grep -q 'install standard pearl aqueous-shell-pearl --ui-mode' "$base/install-log"
[[ $($binary --worker active-selection) == dms && $($binary --worker selection) == pearl ]]
export AQUEOUS_SESSION_RUNTIME=$base/no-runtime
printf 'Split runtime delegation and shell preset installation: passed\n'

reset
rm "$base/config/aqueous/session.toml"
mkdir -p "$base/state/aqueous"
touch "$base/state/aqueous/welcome-v1"
rm "$base/bin/pearl" "$base/bin/noctalia"
# Isolate PATH completely so the test cannot discover a host shell executable.
[[ $(PATH="$base/bin" "$binary" --worker selection) == dms ]]
printf 'Legacy completed-welcome selection fallback: passed\n'
