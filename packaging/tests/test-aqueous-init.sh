#!/usr/bin/env bash
set -euo pipefail
unset LD_PRELOAD

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d /tmp/aqueous-init-test.XXXXXX)
trap 'rm -rf "$test_root"' EXIT

run_init() (
    export HOME="$test_root/home"
    export XDG_CONFIG_HOME="$test_root/config"
    export AQUEOUS_SHARE_DIR="$repo_root/packaging"
    unset DISPLAY WAYLAND_DISPLAY UWSM_FINALIZE_SOCK
    export PATH=/nonexistent

    mkdir() { /usr/bin/mkdir "$@"; }
    cp() { /usr/bin/cp "$@"; }
    chmod() { /usr/bin/chmod "$@"; }
    systemctl() { :; }

    # aqueous-init deliberately exits after seeding and session setup, so run
    # it in this isolated subshell.
    source "$repo_root/packaging/aqueous-init"
)

run_init

ghostty_config="$test_root/config/ghostty/config.ghostty"
test -f "$ghostty_config"
grep -Fx 'window-decoration = none' "$ghostty_config" >/dev/null
test "$(stat -c '%a' "$ghostty_config")" = 600

printf '%s\n' 'window-decoration = client' >"$ghostty_config"
run_init
test "$(cat "$ghostty_config")" = 'window-decoration = client'

echo "Aqueous first-launch config seeding tests passed"

# System session defaults must not pin every login to Adwaita. Cursor values
# belong to the user environment and should remain either absent or unchanged.
(
    unset XCURSOR_THEME XCURSOR_SIZE
    # shellcheck source=../uwsm/env-aqueous
    source "$repo_root/packaging/uwsm/env-aqueous"
    test -z "${XCURSOR_THEME+x}"
    test -z "${XCURSOR_SIZE+x}"
)
(
    export XCURSOR_THEME=Bibata-Modern-Ice
    export XCURSOR_SIZE=32
    # shellcheck source=../uwsm/env-aqueous
    source "$repo_root/packaging/uwsm/env-aqueous"
    test "$XCURSOR_THEME" = Bibata-Modern-Ice
    test "$XCURSOR_SIZE" = 32
)

! grep -Eq 'XCURSOR_(THEME|SIZE)=.*Adwaita|XCURSOR_(THEME|SIZE).*:-' \
    "$repo_root/packaging/aqueous-wm.sh" \
    "$repo_root/packaging/uwsm/env-aqueous"

echo "Aqueous cursor environment tests passed"
