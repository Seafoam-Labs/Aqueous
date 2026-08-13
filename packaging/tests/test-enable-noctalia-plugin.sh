#!/usr/bin/env bash
set -euo pipefail
unset LD_PRELOAD

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
helper="$repo_root/packaging/enable-noctalia-plugin.sh"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

run_helper() {
    local mode=$1
    local state_dir=$2
    local call_log=$3

    (
        noctalia() {
            printf '%s\n' "$*" >>"$call_log"
            if [[ $* == "msg plugins list" && $mode == enabled ]]; then
                printf '%s\n' "aqueous/settings [aqueous] 0.1.0 enabled"
            fi
        }

        export XDG_STATE_HOME="$state_dir"
        # Source the helper so the shell function above stands in for Noctalia.
        # The helper exits the subshell when it completes.
        source "$helper"
    )
}

enabled_state="$test_root/enabled-state"
enabled_log="$test_root/enabled-calls"
run_helper enabled "$enabled_state" "$enabled_log"
test -e "$enabled_state/aqueous/noctalia-settings-enabled-v1"
test "$(wc -l <"$enabled_log")" -eq 1
grep -Fx "msg plugins list" "$enabled_log" >/dev/null

legacy_state="$test_root/legacy-state"
legacy_log="$test_root/legacy-calls"
run_helper legacy "$legacy_state" "$legacy_log"
test -e "$legacy_state/aqueous/noctalia-settings-enabled-v1"
test "$(wc -l <"$legacy_log")" -eq 3
grep -Fx "msg plugins source add aqueous path /usr/share/aqueous/noctalia-plugins" "$legacy_log" >/dev/null
grep -Fx "msg plugins enable aqueous/settings" "$legacy_log" >/dev/null

disabled_state="$test_root/disabled-state"
disabled_log="$test_root/disabled-calls"
mkdir -p "$disabled_state/aqueous"
touch "$disabled_state/aqueous/noctalia-settings-enabled-v1"
run_helper legacy "$disabled_state" "$disabled_log"
test ! -e "$disabled_log"

echo "Noctalia plugin enable hook tests passed"
