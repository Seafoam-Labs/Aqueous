#!/usr/bin/env bash
# Optional session runtime. Never install packages or edit compositor TOML.
set -euo pipefail
config_home=${XDG_CONFIG_HOME:-$HOME/.config}
system_config=${AQUEOUS_SYSCONFDIR:-/etc}
share=${AQUEOUS_SHARE_DIR:-/usr/share/aqueous}
units=${AQUEOUS_UNIT_DIR:-/usr/lib/systemd/user}
snapshot=${XDG_RUNTIME_DIR:-/nonexistent}/aqueous/welcome-session.json
fail() { printf 'Aqueous session: %s\n' "$*" >&2; return 1; }
valid_shell() { case $1 in pearl|dms|noctalia|none) return 0;; *) return 1;; esac; }
in_aqueous() { local desktop=${XDG_CURRENT_DESKTOP:-}; case :${desktop,,}: in *:aqueous:*) return 0;; *) return 1;; esac; }
bounded() { [[ ! -L $1 && -f $1 && $(stat -c %s -- "$1") -le 1048576 ]]; }
selection_file() {
    bounded "$1" || { fail "Not a bounded regular selection file: $1"; return 1; }
    # session.toml is a versioned two-field document written by welcome/Nix.
    # Accept comments, whitespace and either TOML string delimiter. Fail closed
    # on duplicate fields or syntax outside this contract; never source it.
    awk '
        { sub(/\r$/, ""); sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
        /^$/ { next }
        /^version[ \t]*=[ \t]*1$/ { if (version++) bad=1; next }
        /^shell[ \t]*=[ \t]*("(pearl|dms|noctalia|none)"|\047(pearl|dms|noctalia|none)\047)$/ {
            if (shell++) bad=1; sub(/^[^=]*=[ \t]*/, ""); value=substr($0,2,length($0)-2); next
        }
        { bad=1 }
        END { if (bad || version != 1 || shell != 1) exit 1; print value }
    ' "$1" || fail "Invalid session selection in $1; review it in aqueous-welcome."
}
selection() {
    local path=$config_home/aqueous/session.toml found=() shell command
    if [[ -e $path || -L $path ]]; then selection_file "$path"; return; fi
    path=$system_config/xdg/aqueous/session.toml
    if [[ -e $path || -L $path ]]; then selection_file "$path"; return; fi
    path=$config_home/aqueous/wm.toml
    if [[ -e $path || -L $path ]]; then
        bounded "$path" || { fail "Invalid legacy configuration: $path"; return 1; }
        for shell in dms noctalia pearl; do
            command=$shell; [[ $shell != pearl ]] || command=pearlctl
            if grep -qF "$command " "$path"; then found+=("$shell"); fi
        done
    fi
    case ${#found[@]} in
        0) printf 'none\n';;
        1) printf '%s\n' "${found[0]}";;
        *) fail 'Ambiguous legacy shell selection; review it in aqueous-welcome.';;
    esac
}
active_selection() {
    local selected
    if bounded "$snapshot" && selected=$(jq -er --arg display "${WAYLAND_DISPLAY:-}" \
        'select(.display == $display) | .shell | select(. == "none" or . == "dms" or . == "noctalia" or . == "pearl")' "$snapshot" 2>/dev/null); then
        printf '%s\n' "$selected"
    else selection; fi
}
recover() {
    printf 'Aqueous session: %s\n' "$1" >&2
    if command -v aqueous-welcome >/dev/null; then
        aqueous-welcome --message "$1" </dev/null >/dev/null 2>&1 &
    fi
    return 0
}
atomic() (
    local path=$1 directory temporary
    directory=$(dirname -- "$path")
    [[ ! -e $path && ! -L $path ]] || bounded "$path" || { fail "Refusing to replace $path"; exit 1; }
    umask 077
    mkdir -p -- "$directory"
    temporary=$(mktemp "$directory/.session.XXXXXXXX")
    trap 'rm -f -- "$temporary"' EXIT
    cat > "$temporary"
    sync -f "$temporary"
    if [[ ${2:-replace} == new ]]; then
        # Preserve a user file created concurrently with default seeding.
        ln -T -- "$temporary" "$path" 2>/dev/null || [[ -e $path ]]
    else
        mv -fT -- "$temporary" "$path"
    fi
    sync -f "$directory"
)
prepare_session() {
    in_aqueous && [[ ${AQUEOUS_NESTED:-0} != 1 ]] || return 0
    local shell=none selected
    if selected=$(selection); then
        if [[ $selected == none ]] || { command -v "$selected" >/dev/null && [[ -f $units/aqueous-$selected.service ]]; }; then
            shell=$selected
        else recover 'The selected shell or its Aqueous integration is missing. Install its aqueous-shell preset or review setup.'; fi
    else recover 'Invalid or ambiguous shell selection; review session.toml or run aqueous-welcome.'; fi
    [[ -n ${XDG_RUNTIME_DIR:-} ]] || { fail 'XDG_RUNTIME_DIR is required'; return 1; }
    jq -n --arg shell "$shell" --arg display "${WAYLAND_DISPLAY:-}" '{shell:$shell,display:$display}' | atomic "$snapshot"
    if [[ $shell == noctalia && ! -e $config_home/noctalia/config.toml && -f $share/noctalia/config.toml ]]; then
        atomic "$config_home/noctalia/config.toml" new < "$share/noctalia/config.toml"
    fi
}
action() {
    local shell geometry
    shell=$(active_selection)
    case $1 in
        screenshot)
            geometry=$(timeout 30 slurp) || return
            [[ -n $geometry ]] || return 0
            grim -g "$geometry" - | wl-copy --type image/png
            return;;
        chooser)
            case $shell in
                dms) exec "${AQUEOUS_DMS_CHOOSER:-$(dirname -- "${BASH_SOURCE[0]}")/aqueous-dms-portal-chooser}";;
                noctalia) exec noctalia dmenu -p 'Select a source to share:';;
                *) exec aqueous-welcome --choose;;
            esac;;
    esac
    case $shell:$1 in
        pearl:launcher) exec pearlctl launcher toggle;;
        pearl:lock) exec pearlctl lock;;
        dms:launcher) exec dms ipc call spotlight toggle;;
        dms:lock) exec dms ipc call lock lock;;
        noctalia:launcher) exec noctalia msg panel-toggle launcher;;
        noctalia:lock) exec noctalia msg lock;;
        none:launcher) exec aqueous-welcome;;
        none:lock) exec aqueous-welcome --message 'No screen locker is configured for this shell-free session.';;
        *) fail "Unknown action: $1";;
    esac
}
case ${1:-} in
    selection) selection;;
    active-selection) active_selection;;
    prepare-session) prepare_session;;
    external-condition) ! in_aqueous;;
    condition) in_aqueous && [[ ${AQUEOUS_NESTED:-0} != 1 ]] && valid_shell "${2:-}" && [[ $(active_selection) == "$2" ]];;
    action) action "${2:-}";;
    recover) recover 'Your desktop shell failed to start. Review its journal or run aqueous-welcome.';;
    *) fail 'Usage: session-runtime.sh selection|active-selection|prepare-session|condition SHELL|external-condition|action NAME|recover';;
esac
