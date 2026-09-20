#!/usr/bin/env bash
# Shared packaging primitives. Source this file; no host configuration is changed.
aqueous_components=(core session welcome portal integration-dms integration-noctalia integration-pearl)
aq_die() { printf 'aqueous packaging: %s\n' "$*" >&2; exit 1; }
aq_hash() { local hash; hash=$(sha256sum -- "$1") || return; printf '%s\n' "${hash%% *}"; }
aq_component() { local item; for item in "${aqueous_components[@]}"; do [[ $1 != "$item" ]] || return 0; done; aq_die "Unknown component: $1"; }
aq_empty_root() {
    [[ -n $1 && $1 == /* && $1 != / ]] || aq_die 'A private absolute destination is required'
    [[ $(realpath -m -s -- "$1") == "$(realpath -m -- "$1")" ]] || aq_die 'Destination must not contain symlinks'
    mkdir -p -- "$1"
    [[ -z $(find "$1" -mindepth 1 -print -quit) ]] || aq_die 'Destination must be empty'
}
aq_policy() {
    jq -e '(.input_activity_testing // false) == false and (.warming_testing // false) == false and (del(.input_activity_testing, .warming_testing) == {schema:1, output_retry_testing:false, display_preview_acceptance:false})' "$1" >/dev/null || aq_die 'Refusing non-production compositor policy'
}
