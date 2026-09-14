#!/usr/bin/env bash
# Verify every component before a binary package copies any payload.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/components/common.sh"
[[ $# == 5 && $2 == --version && $4 == --architecture ]] || aq_die 'Usage: verify-release.sh ROOT --version VERSION --architecture ARCH'
root=$1
jq -e --arg version "$3" --arg architecture "$5" \
    '.version == $version and .architecture == $architecture and .variant == "release"' "$root/cohort.json" >/dev/null || aq_die 'Release version/architecture/variant mismatch'
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
jq -S . "$root/cohort.json" > "$temporary/cohort"
for component in "${aqueous_components[@]}"; do
    manifest=$root/$component/manifest.json
    jq -e --arg c "$component" '.component == $c' "$manifest" >/dev/null || aq_die 'Component identity mismatch'
    jq -S .cohort "$manifest" > "$temporary/component-cohort"
    cmp -s "$temporary/cohort" "$temporary/component-cohort" || aq_die 'Component cohort mismatch'
    "$here/component-artifacts.sh" verify "$root/$component/root" "$manifest"
    jq -r '.files[].path' "$manifest" >> "$temporary/paths"
done
[[ -z $(sort "$temporary/paths" | uniq -d) ]] || aq_die 'Duplicate ownership'
core=$root/core/root/usr
readelf -d "$core/bin/aqueous" > "$temporary/elf"
grep -qF '$ORIGIN/../lib/aqueous' "$temporary/elf" || aq_die 'Missing private compositor library path'
! grep -qi scenefx "$temporary/elf" || aq_die 'Unexpected SceneFX linkage'
"$core/bin/aqueous" -version >/dev/null
"$core/bin/aqueous-config" version --shell none | jq -S . > "$temporary/helper"
jq -S .helper "$root/cohort.json" > "$temporary/expected-helper"
cmp -s "$temporary/helper" "$temporary/expected-helper" || aq_die 'Helper version/capabilities mismatch'
