#!/usr/bin/env bash
# Shell regression tests for staging, ownership, archives and session behavior.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$root/packaging/components/common.sh"
base=$(mktemp -d /tmp/aqueous-shell-components.XXXXXXXX)
trap 'rm -rf -- "$base"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reject() { if "$@" > "$base/rejected.log" 2>&1; then fail "Unexpected success: $*"; fi; }
assert_no() { [[ ! -e $1 && ! -L $1 ]] || fail "Unexpected path: $1"; }
artifacts=$root/packaging/component-artifacts.sh
build=$base/build
for path in bin/aqueous bin/aqueous-activity-launch bin/aqueousctl bin/aqueous-config bin/aqueous-welcome bin/aqueous-dms-portal-chooser \
    lib/aqueous/libwlroots-0.20.so share/man/man1/aqueous.1 share/man/man1/aqueousctl.1 \
    share/aqueous-protocols/experimental/aqueous-capture-color-v1.xml share/pkgconfig/aqueous-protocols.pc; do
    install -d "$build/$(dirname "$path")"
    printf '#!/bin/sh\nexit 0\n' > "$build/$path"
    chmod 755 "$build/$path"
done
install -d "$build/share/aqueous"
printf '%s\n' '{"schema":1,"output_retry_testing":false,"display_preview_acceptance":false}' > "$build/share/aqueous/build-policy.json"
export AQUEOUS_COMPOSITOR_DIST=$build AQUEOUS_CONFIG_BINARY=$build/bin/aqueous-config
export AQUEOUS_WELCOME_BINARY=$build/bin/aqueous-welcome AQUEOUS_PORTAL_BINARY=$build/bin/aqueous
export AQUEOUS_PORTAL_LICENSE=$build/bin/aqueous AQUEOUS_PORTAL_CHOOSER_BINARY=$build/bin/aqueous-dms-portal-chooser
printf '%s\n' '{"revision":"fixture","version":"test","architecture":"x86_64","variant":"fixture"}' > "$base/cohort.json"
# No staging operation may invoke a host-management command.
mkdir "$base/spies"
for command in systemctl sudo pacman dnf; do
    printf '#!/bin/sh\necho unexpected >> "%s"\nexit 97\n' "$base/side-effects" > "$base/spies/$command"
    chmod 755 "$base/spies/$command"
done
export PATH="$base/spies:$PATH"
pairs=()
for component in "${aqueous_components[@]}"; do
    DESTDIR="$base/$component" "$root/packaging/stage-component.sh" "$component"
    "$artifacts" manifest "$component" "$base/$component" "$base/cohort.json" "$base/$component.json"
    pairs+=("$base/$component=$base/$component.json")
done
assert_no "$base/side-effects"
"$artifacts" compose "$base/desktop" "${pairs[@]}"
assert_no "$base/core/etc"
assert_no "$base/core/usr/lib/systemd"
assert_no "$base/core/usr/bin/aqueous-welcome"
assert_no "$base/desktop/usr/lib/udev"
reject "$artifacts" compose "$base/duplicate" "${pairs[0]}" "${pairs[0]}"
printf 'tampered\n' >> "$base/core/usr/bin/aqueous"
reject "$artifacts" verify "$base/core" "$base/core.json"
cp "$build/bin/aqueous" "$base/core/usr/bin/aqueous"
touch "$base/core/usr/bin/aqueous-settings"
reject "$artifacts" manifest core "$base/core" "$base/cohort.json" "$base/bad.json"
rm "$base/core/usr/bin/aqueous-settings"
jq '.cohort.revision="other"' "$base/session.json" > "$base/other.json"
reject "$artifacts" compose "$base/mixed" "${pairs[0]}" "$base/session=$base/other.json"
for flag in output_retry_testing display_preview_acceptance input_activity_testing warming_testing; do
    jq --arg flag "$flag" '.[$flag]=true' "$base/core/usr/share/aqueous/build-policy.json" > "$build/share/aqueous/build-policy.json"
    reject env DESTDIR="$base/$flag" "$root/packaging/stage-component.sh" core
done
cp "$base/core/usr/share/aqueous/build-policy.json" "$build/share/aqueous/build-policy.json"
reject env DESTDIR="$base/core" "$root/packaging/stage-component.sh" core
ln -s "$base" "$base/alias"
reject env DESTDIR="$base/alias/escape" "$root/packaging/stage-component.sh" session
assert_no "$base/escape"
for component in "${aqueous_components[@]}"; do
    DESTDIR="$base/relocated/$component" PREFIX=/opt/aqueous SYSCONFDIR=/opt/config "$root/packaging/stage-component.sh" "$component"
    assert_no "$base/relocated/$component/usr"
    assert_no "$base/relocated/$component/etc"
done
! grep -q 'python\|welcome-setup' "$base/session/usr/bin/aqueous-init"
! grep -Rq 'python' "$base/session/usr/lib/systemd"
assert_no "$base/welcome/usr/lib/aqueous/welcome-setup.py"
# Standalone runtime: there is no welcome payload in this root.
runtime=$base/session/usr/lib/aqueous/session-runtime.sh
export HOME=$base/home XDG_CONFIG_HOME=$base/config XDG_STATE_HOME=$base/state XDG_RUNTIME_DIR=$base/run
export AQUEOUS_SYSCONFDIR=$base/etc AQUEOUS_UNIT_DIR=$base/units XDG_CURRENT_DESKTOP=Aqueous WAYLAND_DISPLAY=wayland-test AQUEOUS_NESTED=0
mkdir -p "$HOME" "$XDG_CONFIG_HOME/aqueous" "$AQUEOUS_UNIT_DIR" "$XDG_RUNTIME_DIR"
select_shell() { printf 'version = 1\nshell = "%s"\n' "$1" > "$XDG_CONFIG_HOME/aqueous/session.toml"; }
[[ $("$runtime" selection) == none ]]
printf '#!/bin/sh\nexit 0\n' > "$base/spies/dms"; chmod 755 "$base/spies/dms"
[[ $("$runtime" selection) == none ]] # Installed apps cannot select a shell.
select_shell dms
cp "$XDG_CONFIG_HOME/aqueous/session.toml" "$base/before"
"$runtime" prepare-session
[[ $("$runtime" active-selection) == none ]]
cmp "$base/before" "$XDG_CONFIG_HOME/aqueous/session.toml"
touch "$AQUEOUS_UNIT_DIR/aqueous-dms.service"
"$runtime" prepare-session
select_shell pearl
"$runtime" condition dms
reject "$runtime" condition pearl
XDG_CURRENT_DESKTOP=Other "$runtime" external-condition
reject env XDG_CURRENT_DESKTOP=Other "$runtime" condition dms
select_shell unknown
cp "$XDG_CONFIG_HOME/aqueous/session.toml" "$base/before"
"$runtime" prepare-session
[[ $("$runtime" active-selection) == none ]]
cmp "$base/before" "$XDG_CONFIG_HOME/aqueous/session.toml"
# Malicious/duplicate TOML is rejected without execution.
printf 'version=1\nshell="dms"\nshell="none"\n' > "$XDG_CONFIG_HOME/aqueous/session.toml"
reject "$runtime" selection
printf 'version=1\nshell="$(touch %s)"\n' "$base/executed" > "$XDG_CONFIG_HOME/aqueous/session.toml"
reject "$runtime" selection
assert_no "$base/executed"
printf " # comment\nversion = 1\nshell = 'none' # comment\n" > "$XDG_CONFIG_HOME/aqueous/session.toml"
[[ $("$runtime" selection) == none ]]
# Safe archive extraction cannot write through an archive-owned symlink.
mkdir "$base/archive" "$base/archive-escape"
ln -s "$base/archive-escape" "$base/archive/usr"
tar -cf "$base/bad.tar" -C "$base/archive" usr
rm "$base/archive/usr"; mkdir "$base/archive/usr"; touch "$base/archive/usr/escape"
tar -rf "$base/bad.tar" -C "$base/archive" usr/escape
reject "$artifacts" extract "$base/bad.tar" "$base/extracted"
assert_no "$base/archive-escape/escape"
# Reinstall/removal uses only recorded payload paths and preserves user config.
dist=$base/dist; mkdir "$dist"
for name in aqueous-dist aqueous-config-dist aqueous-welcome-dist aqueous-portal-chooser-dist; do ln -s "$build" "$dist/$name"; done
install -Dm755 "$build/bin/aqueous" "$dist/aqueous-portal-dist/usr/lib/aqueous/xdg-desktop-portal-aqueous"
install -Dm644 "$build/bin/aqueous" "$dist/aqueous-portal-dist/usr/share/licenses/aqueous/xdg-desktop-portal-wlr/LICENSE"
export AQUEOUS_DIST=$dist AQUEOUS_PREFIX=$base/gentoo
mkdir "$AQUEOUS_PREFIX"; touch "$AQUEOUS_PREFIX/unrelated"
bash "$root/scripts/gentoo-install.sh" --core-only install > "$base/gentoo.log"
assert_no "$AQUEOUS_PREFIX/etc"
bash "$root/scripts/gentoo-install.sh" install >> "$base/gentoo.log"
printf '# user settings\n' > "$AQUEOUS_PREFIX/etc/xdg/aqueous/wm.toml"
bash "$root/scripts/gentoo-install.sh" install >> "$base/gentoo.log"
grep -qx '# user settings' "$AQUEOUS_PREFIX/etc/xdg/aqueous/wm.toml"
[[ -f $AQUEOUS_PREFIX/etc/xdg/aqueous/wm.toml.aqnew ]]
bash "$root/scripts/gentoo-install.sh" uninstall >> "$base/gentoo.log"
grep -qx '# user settings' "$AQUEOUS_PREFIX/etc/xdg/aqueous/wm.toml"
[[ -f $AQUEOUS_PREFIX/unrelated ]]
assert_no "$AQUEOUS_PREFIX/usr/bin/aqueous"
# Fedora's core spec and skip-dependency path need no Python orchestration.
(
    source "$root/scripts/fedora-install.sh"
    fedora_component=core
    fedora_skip_deps=true
    fedora_dependencies
    fedora_work=$base/fedora
    mkdir -p "$fedora_work/payload/usr/bin"
    cp "$build/bin/aqueous" "$fedora_work/payload/usr/bin/aqueous"
    printf '0.7.0\n' > "$fedora_work/version"
    rpmbuild() {
        mkdir -p "$fedora_work/rpmbuild/RPMS/x86_64"
        touch "$fedora_work/rpmbuild/RPMS/x86_64/aqueous-core-fixture.rpm"
    }
    rpm() { printf 'libc.so.6\n'; }
    fedora_make_rpm > "$base/fedora.log"
    grep -qx 'Name: aqueous-core' "$fedora_work/rpmbuild/SPECS/aqueous-git.spec"
    ! grep -q '^Requires: dms\|^Provides: aqueous =' "$fedora_work/rpmbuild/SPECS/aqueous-git.spec"
    grep -qx '"/usr/bin/aqueous"' "$fedora_work/rpmbuild/SOURCES/files.list"
)
reject bash "$root/scripts/fedora-install.sh" --core-only --dms-git
assert_no "$base/side-effects"
printf 'PASS: shell component ownership, manifests, relocation, session recovery, archive safety and installer preservation\n'
