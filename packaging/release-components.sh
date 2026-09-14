#!/usr/bin/env bash
# Build checked component archives and a checksum-pinned binary recipe.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/packaging/components/common.sh"
[[ $# == 5 && $2 == --version && $4 == --architecture ]] || aq_die 'Usage: release-components.sh OUTPUT --version VERSION --architecture ARCH'
output=$(realpath -m -s -- "$1")
version=$3
architecture=$5
[[ $version =~ ^[0-9]+(\.[0-9]+)+[a-zA-Z0-9.+]*$ ]] || aq_die 'Use a numeric release version without a v prefix'
case $architecture in x86_64) suffix=x64;; aarch64) suffix=arm64;; *) aq_die 'Unsupported architecture';; esac
components=$output/components
[[ ! -e $components ]] || aq_die 'Release components already exist'
aq_empty_root "$components"
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
helper=${AQUEOUS_CONFIG_BINARY:?Set AQUEOUS_CONFIG_BINARY}
compositor=${AQUEOUS_COMPOSITOR_DIST:?Set AQUEOUS_COMPOSITOR_DIST}
"$helper" version --shell none > "$temporary/helper.json"
for patch in "$root/compositor/patches/wlroots/"*.patch; do
    jq -cn --arg name "${patch##*/}" --arg hash "$(aq_hash "$patch")" '{key:$name,value:$hash}'
done | jq -s from_entries > "$temporary/patches.json"
dirty=false
[[ -z $(git -C "$root" status --porcelain) ]] || dirty=true
jq -n --arg revision "$(git -C "$root" rev-parse HEAD)" --arg version "$version" \
    --arg architecture "$architecture" --argjson dirty "$dirty" \
    --arg compositor_version "$("$compositor/bin/aqueous" -version)" \
    --arg library "$(aq_hash "$compositor/lib/aqueous/libwlroots-0.20.so")" \
    --slurpfile helper "$temporary/helper.json" --slurpfile patches "$temporary/patches.json" \
    '{revision:$revision,version:$version,architecture:$architecture,variant:"release",source_dirty:$dirty,
      compositor_version:$compositor_version,helper:$helper[0],wlroots_patches:$patches[0],wlroots_sha256:$library}' > "$components/cohort.json"
pairs=()
for component in "${aqueous_components[@]}"; do
    DESTDIR="$components/$component/root" "$root/packaging/stage-component.sh" "$component"
    "$root/packaging/component-artifacts.sh" manifest "$component" "$components/$component/root" "$components/cohort.json" "$components/$component/manifest.json"
    pairs+=("$components/$component/root=$components/$component/manifest.json")
done
install -d "$components/tools/components"
for file in component-artifacts.sh verify-release.sh components.json; do cp "$root/packaging/$file" "$components/tools/$file"; done
cp "$root/packaging/components/common.sh" "$components/tools/components/common.sh"
"$components/tools/verify-release.sh" "$components" --version "$version" --architecture "$architecture"
"$root/packaging/component-artifacts.sh" compose "$output/desktop-root" "${pairs[@]}"
legacy=$output/aqueous-linux-$suffix
cp -a "$output/desktop-root/usr" "$legacy"
cp -a "$output/desktop-root/etc" "$legacy/etc"
archives=("Aqueous-linux-$suffix.tar.gz" "Aqueous-components-$version-$architecture.tar.gz")
tar -czf "$output/${archives[0]}" -C "$legacy" .
tar -czf "$output/${archives[1]}" -C "$output" components
for component in "${aqueous_components[@]}"; do
    archive=Aqueous-$component-$version-$architecture.tar.gz
    tar -czf "$output/$archive" -C "$components" "$component"
    archives+=("$archive")
done
"$root/packaging/component-artifacts.sh" extract "$output/${archives[1]}" "$temporary/extracted"
"$temporary/extracted/components/tools/verify-release.sh" "$temporary/extracted/components" --version "$version" --architecture "$architecture"
sed -e "s/^pkgver=.*/pkgver=$version/" -e "s/REPLACE_WITH_RELEASE_SHA256/$(aq_hash "$output/${archives[1]}")/" \
    "$root/PKGBUILD-bin" > "$output/PKGBUILD-bin"
archives+=(PKGBUILD-bin)
(cd "$output" && sha256sum -- "${archives[@]}" > SHA256SUMS.txt)
