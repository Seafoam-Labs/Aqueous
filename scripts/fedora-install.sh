#!/usr/bin/env bash
# Build upstream master as a local RPM, using its source-package recipe.
set -euo pipefail

fedora_repo=https://github.com/Seafoam-Labs/Aqueous.git
fedora_build_only=false
fedora_skip_deps=false
fedora_dms_git=false
fedora_yes=()
fedora_output=${AQUEOUS_FEDORA_OUTPUT:-${XDG_CACHE_HOME:-$HOME/.cache}/aqueous/fedora}

fedora_die() { printf 'fedora-install: %s\n' "$*" >&2; exit 1; }
fedora_say() { printf 'fedora-install: %s\n' "$*"; }

fedora_usage() {
    cat <<'EOF'
Usage: bash scripts/fedora-install.sh [options]

Fetch Seafoam-Labs/Aqueous master, build and test it as your normal user,
then install a local aqueous-git RPM through sudo dnf.

  --build-only       Produce the RPM without installing Aqueous
  --skip-deps        Use dependencies already installed on the build machine
  --dms-git          Enable avengemedia/dms-git COPR for the DMS dependency
  -y, --yes          Accept DNF transaction prompts
  -h, --help         Show this help

Requires mutable Fedora (DNF), x86_64 or aarch64, and sudo access for DNF.
Run without sudo; only package-manager transactions need root.
Builds and RPMs are kept in AQUEOUS_FEDORA_OUTPUT (default:
${XDG_CACHE_HOME:-$HOME/.cache}/aqueous/fedora), one directory per invocation.
Run again to install current master. Remove with: sudo dnf remove aqueous-git
--build-only still installs build dependencies unless --skip-deps is also set.
EOF
}

fedora_host_check() {
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ ${ID:-} == fedora ]] || fedora_die 'This installer requires Fedora.'
    [[ ! -e /run/ostree-booted && ! -e /usr/lib/bootc ]] ||
        fedora_die 'Use a mutable Fedora installation; Atomic/bootc hosts need image-based packaging.'
    [[ $EUID -ne 0 ]] || fedora_die 'Run as your normal user, without sudo. DNF will request sudo when needed.'
    case $(uname -m) in
        x86_64|aarch64) ;;
        *) fedora_die 'Only x86_64 and aarch64 are supported by the source package.' ;;
    esac
    command -v dnf >/dev/null || fedora_die 'dnf is required.'
    if ! $fedora_skip_deps || ! $fedora_build_only; then
        command -v sudo >/dev/null || fedora_die 'sudo is required for package installation.'
    fi
}

fedora_dependencies() {
    $fedora_skip_deps && return 0
    if $fedora_dms_git; then
        fedora_say 'Enabling the upstream avengemedia/dms-git COPR repository.'
        sudo dnf "${fedora_yes[@]}" install 'dnf-command(copr)'
        sudo dnf "${fedora_yes[@]}" copr enable avengemedia/dms-git
    fi
    # pkg-config capabilities avoid differences in Fedora's -devel names.
    sudo dnf "${fedora_yes[@]}" --refresh install \
        git curl patch tar gzip xz gcc gcc-c++ clang llvm lld binutils \
        rpm-build redhat-rpm-config meson ninja-build pkgconf-pkg-config \
        scdoc glslang glslc hwdata python3 jq ripgrep desktop-file-utils \
        qt6-qtdeclarative-devel gsettings-desktop-schemas \
        'zig >= 0.16.0' 'pkgconfig(wayland-protocols) >= 1.49' \
        'pkgconfig(wayland-server)' 'pkgconfig(wayland-client)' \
        'pkgconfig(wayland-scanner)' 'pkgconfig(xkbcommon)' \
        'pkgconfig(libinput)' 'pkgconfig(libevdev)' 'pkgconfig(pixman-1)' \
        'pkgconfig(libdrm)' 'pkgconfig(gbm)' 'pkgconfig(egl)' \
        'pkgconfig(glesv2)' 'pkgconfig(libudev)' 'pkgconfig(libseat)' \
        'pkgconfig(libdisplay-info)' 'pkgconfig(libliftoff)' 'pkgconfig(lcms2)' \
        'pkgconfig(vulkan)' 'pkgconfig(freetype2)' 'pkgconfig(fontconfig)' \
        'pkgconfig(libpng)' 'pkgconfig(libpipewire-0.3)' 'pkgconfig(inih)' \
        'pkgconfig(xcb)' 'pkgconfig(xcb-errors)' 'pkgconfig(xcb-icccm)' \
        'pkgconfig(xcb-renderutil)' 'pkgconfig(libsystemd)' \
        xorg-x11-server-Xwayland
    # Resolve session dependencies before spending time compiling. DMS can
    # come from enabled repositories or the explicitly selected upstream COPR.
    sudo dnf "${fedora_yes[@]}" install \
        'dms >= 1.6.1' uwsm foot nemo grim slurp wl-clipboard libnotify \
        glib2 fontconfig freetype libdecor libXcursor vulkan-loader \
        mesa-vulkan-drivers pipewire wireplumber xdg-desktop-portal \
        xdg-desktop-portal-gtk
}

fedora_tools_check() {
    local tool
    for tool in git curl patch tar cc zig meson ninja pkg-config sha256sum \
        rpmbuild rpm readelf scdoc python3 jq rg glslc; do
        command -v "$tool" >/dev/null || fedora_die "Missing $tool; run without --skip-deps."
    done
    local version
    version=$(zig version)
    printf '0.16.0\n%s\n' "${version%%-*}" | sort -V -C ||
        fedora_die "Zig >= 0.16.0 is required; found $version."
    pkg-config --atleast-version=1.49 wayland-protocols ||
        fedora_die 'wayland-protocols >= 1.49 is required. Update Fedora packages before retrying.'
    # Fedora exposes Qt tools with a -qt6 suffix, unlike the Arch recipe.
    export QMLTESTRUNNER=${QMLTESTRUNNER:-$(command -v qmltestrunner-qt6 || true)}
    export QMLFORMAT=${QMLFORMAT:-$(command -v qmlformat-qt6 || true)}
    [[ -x $QMLTESTRUNNER && -x $QMLFORMAT ]] ||
        fedora_die 'Install qt6-qtdeclarative-devel, or set QMLTESTRUNNER and QMLFORMAT to the Qt 6 executables.'
}

fedora_build_source() (
    # Keep upstream recipe variables/functions isolated from the installer.
    srcdir=$fedora_work/source
    pkgdir=$fedora_work/payload
    mkdir -p "$srcdir" "$pkgdir"
    git clone --depth 1 --single-branch --branch master "$fedora_repo" "$srcdir/aqueous"
    cd "$srcdir/aqueous"
    git rev-parse HEAD > "$fedora_work/commit"
    fedora_say "Building master at $(cat "$fedora_work/commit")"
    # PKGBUILD is the project's maintained DMS build/check/install recipe.
    # Only its source phases run; pacman dependencies and install hooks do not.
    msg2() { fedora_say "$*"; }
    msg() { fedora_say "$*"; }
    error() { printf 'Aqueous build: %s\n' "$*" >&2; }
    # shellcheck disable=SC1091
    source ./PKGBUILD
    local phase entry archive url checksum index
    for phase in prepare build check package; do
        declare -F "$phase" >/dev/null || fedora_die "master PKGBUILD is missing $phase()."
    done
    [[ $pkgver =~ ^[0-9][0-9A-Za-z.+]*$ ]] || fedora_die 'Unsupported upstream package version.'
    printf '%s^git%s.%s\n' "$pkgver" "$(git show -s --format=%ct HEAD)" \
        "$(git rev-parse --short=12 HEAD)" > "$fedora_work/version"
    # The first source is the master checkout above. Fetch pinned dependency
    # archives from this same recipe and verify every checksum before unpacking.
    [[ ${source[0]} == aqueous::git+* ]] || fedora_die 'Unexpected primary source in master PKGBUILD.'
    for ((index=1; index<${#source[@]}; index++)); do
        entry=${source[index]}
        archive=${entry%%::*}
        url=${entry#*::}
        checksum=${sha256sums[index]}
        [[ $archive =~ ^[A-Za-z0-9._+-]+\.tar\.gz$ && $url == https://* &&
            $checksum =~ ^[a-fA-F0-9]{64}$ ]] ||
            fedora_die "Unsupported or unverified dependency source: $entry"
        curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' \
            "$url" -o "$srcdir/$archive"
        printf '%s  %s\n' "$checksum" "$srcdir/$archive" | sha256sum --check -
        tar --extract --gzip --file "$srcdir/$archive" --directory "$srcdir" --no-same-owner
    done
    export ZIG_GLOBAL_CACHE_DIR=$fedora_work/zig-global
    # Run phases in their own subshells, as makepkg does, so a phase's cd
    # cannot change the starting directory for the following phase.
    (cd "$srcdir"; prepare)
    (cd "$srcdir"; build)
    (cd "$srcdir"; check)
    (cd "$srcdir"; package)
    # Fedora's official foot package provides a working default terminal.
    sed -i 's/^spawn_terminal = "ghostty"$/spawn_terminal = "foot"/' \
        "$pkgdir/etc/xdg/aqueous/wm.toml" "$pkgdir/usr/share/aqueous/wm.toml"
    install -Dm644 "$fedora_work/commit" "$pkgdir/usr/share/doc/aqueous/master-commit"
)

fedora_make_rpm() {
    local top=$fedora_work/rpmbuild
    mkdir -p "$top"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
    tar -czf "$top/SOURCES/payload.tar.gz" -C "$fedora_work/payload" .
    # List files individually: recursively owning /usr or /etc would claim
    # directories that belong to Fedora. Own only Aqueous-specific directories.
    python3 - "$fedora_work/payload" > "$top/SOURCES/files.list" <<'PY'
import os, pathlib, sys
root = pathlib.Path(sys.argv[1])
owned = (
    '/usr/lib/aqueous', '/usr/share/aqueous', '/usr/share/aqueous-protocols',
    '/usr/share/doc/aqueous', '/usr/share/licenses/aqueous',
    '/usr/share/licenses/aqueous-settings', '/etc/xdg/aqueous',
    '/etc/xdg/xdg-desktop-portal-aqueous',
)
for directory, dirs, files in os.walk(root):
    for name in sorted(dirs + files):
        path = pathlib.Path(directory, name)
        target = '/' + path.relative_to(root).as_posix()
        if any(c in target for c in '\n\r\t"\\%'):
            raise SystemExit(f'Unsupported RPM path: {target!r}')
        if path.is_dir() and not path.is_symlink():
            if any(target == p or target.startswith(p + '/') for p in owned):
                print(f'%dir "{target}"')
        else:
            flag = '%config(noreplace) ' if target.startswith('/etc/') and not path.is_symlink() else ''
            print(f'{flag}"{target}"')
PY
    cat > "$top/SPECS/aqueous-git.spec" <<'SPEC'
# Local binary packaging: sources were built and checked by fedora-install.sh.
%global debug_package %{nil}
# Preserve Zig artifacts and the exact bundled wlroots checked by upstream.
%global __os_install_post %{nil}
%global _build_id_links none
# The private patched library must never satisfy another RPM's wlroots needs.
%global __provides_exclude ^libwlroots-.*$
%global __requires_exclude ^libwlroots-.*$
Name: aqueous-git
Version: %{aqueous_version}
Release: 1.%{aqueous_build_time}%{?dist}
Summary: Aqueous Wayland compositor built from upstream master
License: GPL-3.0-only AND MIT AND LicenseRef-PX
URL: https://github.com/Seafoam-Labs/Aqueous
Source0: payload.tar.gz
Source1: files.list
Provides: aqueous = %{version}-%{release}
Conflicts: aqueous aqueous-bin aqueous-git-intel aqueous-git-dms
Requires: dms >= 1.6.1
Requires: uwsm foot nemo grim slurp wl-clipboard libnotify glib2
Requires: fontconfig freetype libdecor libXcursor vulkan-loader mesa-vulkan-drivers
Requires: pipewire wireplumber xdg-desktop-portal xdg-desktop-portal-gtk
Requires: xorg-x11-server-Xwayland systemd gsettings-desktop-schemas

%description
Aqueous compositor, settings, DMS integration and private screen-sharing backend.
The exact master commit is recorded in /usr/share/doc/aqueous/master-commit.

%prep
%build
%install
mkdir -p "%{buildroot}"
tar -xzf "%{SOURCE0}" -C "%{buildroot}"

%files -f "%{SOURCE1}"
%defattr(-,root,root,-)
SPEC
    rpmbuild -bb --define "_topdir $top" \
        --define "aqueous_version $(cat "$fedora_work/version")" \
        --define "aqueous_build_time $(date -u +%Y%m%d%H%M%S)" \
        "$top/SPECS/aqueous-git.spec"
    local -a packages
    shopt -s nullglob
    packages=("$top"/RPMS/*/aqueous-git-*.rpm)
    [[ ${#packages[@]} -eq 1 ]] || fedora_die 'Expected exactly one aqueous-git RPM.'
    fedora_rpm=${packages[0]}
    rpm -qp --requires "$fedora_rpm" > "$fedora_work/rpm-requires.txt"
    fedora_say "RPM ready: $fedora_rpm"
}

fedora_main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --build-only) fedora_build_only=true ;;
            --skip-deps) fedora_skip_deps=true ;;
            --dms-git) fedora_dms_git=true ;;
            -y|--yes) fedora_yes=(-y) ;;
            -h|--help) fedora_usage; return ;;
            *) fedora_die "Unknown option: $1 (see --help)" ;;
        esac
        shift
    done
    if $fedora_skip_deps && $fedora_dms_git; then
        fedora_die '--dms-git cannot be combined with --skip-deps.'
    fi
    fedora_host_check
    fedora_dependencies
    fedora_tools_check
    mkdir -p "$fedora_output"
    fedora_output=$(cd "$fedora_output" && pwd)
    # RPM expands these paths into shell fragments. Exclude shell and macro
    # syntax, and colons (which also separate pkg-config search directories).
    [[ $fedora_output =~ ^[a-zA-Z0-9_./\ -]+$ ]] ||
        fedora_die 'Use only letters, numbers, spaces, slashes, dots, underscores and hyphens in the output path.'
    fedora_work=$(mktemp -d "$fedora_output/build.XXXXXXXX")
    fedora_say "Build directory: $fedora_work"
    fedora_build_source
    fedora_make_rpm
    if ! $fedora_build_only; then
        sudo dnf "${fedora_yes[@]}" install "$fedora_rpm"
        fedora_say 'Installed. Log out and select Aqueous in your display manager.'
        fedora_say 'Existing user configuration is retained; new profiles use foot as the terminal.'
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    fedora_main "$@"
fi
