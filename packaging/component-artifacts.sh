#!/usr/bin/env bash
# Validate manifests and compose shell-independent component payloads.
set -euo pipefail
export LC_ALL=C
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/components/common.sh"
contract=$here/components.json
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
jq -e '.schema == 1 and (.components | type == "object")' "$contract" >/dev/null
safe_name() { [[ $1 =~ ^[a-zA-Z0-9_./+-]+$ && $1 != /* && /$1/ != */../* ]]; }
entries() {
    local root=$1 entry name mode target
    [[ -d $root && ! -L $root ]] || aq_die "Invalid payload root: $root"
    while IFS= read -r -d '' entry; do
        name=${entry#"$root/"}
        safe_name "$name" || aq_die "Unsupported payload path: $name"
        if [[ -d $entry && ! -L $entry ]]; then continue; fi
        mode=$(stat -c %a -- "$entry")
        mode=$((8#$mode))
        if [[ -L $entry ]]; then
            target=$(readlink -- "$entry")
            jq -cn --arg path "$name" --argjson mode "$mode" --arg target "$target" '{path:$path,mode:$mode,type:"symlink",target:$target}'
        elif [[ -f $entry ]]; then
            jq -cn --arg path "$name" --argjson mode "$mode" --arg hash "$(aq_hash "$entry")" '{path:$path,mode:$mode,type:"file",sha256:$hash}'
        else aq_die "Unsupported file type: $name"; fi
    done < <(find "$root" -mindepth 1 -print0 | sort -z)
}
validate() {
    local component=$1 root=$2 name pattern allowed mode target resolved parent
    local -a patterns required
    aq_component "$component"
    entries "$root" | jq -s 'sort_by(.path)' > "$scratch/files.json"
    mapfile -t patterns < <(jq -r --arg c "$component" '.components[$c].owns[]' "$contract")
    mapfile -t required < <(jq -r --arg c "$component" '.components[$c].required[]' "$contract")
    for name in "${required[@]}"; do
        jq -e --arg name "$name" 'any(.[]; .path == $name)' "$scratch/files.json" >/dev/null || aq_die "$component: missing $name"
    done
    while IFS=$'\t' read -r name mode; do
        allowed=false
        for pattern in "${patterns[@]}"; do [[ $name != $pattern ]] || allowed=true; done
        $allowed || aq_die "$component: unowned path $name"
        case $name in *river-*|*riverdelta*|*aqueous-backend-test*|*aqueous-settings*|*__pycache__*) aq_die "Retired/test artifact: $name";; esac
        (( (mode & 06000) == 0 )) || aq_die "Privileged file mode: $name"
        if [[ -L $root/$name ]]; then
            target=$(readlink -- "$root/$name")
            [[ $target =~ ^[a-zA-Z0-9_./+-]+$ ]] || aq_die "Unsupported symlink: $name"
            if [[ $target == /* ]]; then resolved=$(realpath -m -s -- "$root/$target")
            else resolved=$(realpath -m -s -- "$root/$(dirname -- "$name")/$target"); fi
            [[ $resolved == "$root/"* ]] || aq_die "Symlink escapes payload: $name"
            # Do not let a second link in the target path resolve via the host.
            parent=$resolved
            while [[ $parent != "$root" ]]; do
                [[ ! -L $parent ]] || aq_die "Symlink chain in payload: $name"
                parent=$(dirname -- "$parent")
            done
            [[ -e $resolved ]] || aq_die "Unresolved symlink: $name"
        fi
    done < <(jq -r '.[] | [.path,.mode] | @tsv' "$scratch/files.json")
    [[ $component != core ]] || aq_policy "$root/usr/share/aqueous/build-policy.json"
}
verify() {
    local root=$1 manifest=$2 component
    jq -e '.schema == 1 and (.component|type == "string") and (.cohort|type == "object") and (.files|type == "array")' "$manifest" >/dev/null || aq_die 'Unsupported manifest'
    component=$(jq -r '.component' "$manifest")
    validate "$component" "$root"
    jq -e --slurpfile actual "$scratch/files.json" '.files == $actual[0]' "$manifest" >/dev/null || aq_die 'Payload does not match manifest'
}
case ${1:-} in
    manifest)
        [[ $# == 5 ]] || aq_die 'Usage: component-artifacts.sh manifest COMPONENT ROOT COHORT OUTPUT'
        jq -e 'all(.revision,.version,.architecture,.variant; type == "string" and length > 0)' "$4" >/dev/null || aq_die 'Incomplete release cohort'
        validate "$2" "$(realpath -m -s -- "$3")"
        jq -n --arg component "$2" --slurpfile cohort "$4" --slurpfile files "$scratch/files.json" \
            '{schema:1,component:$component,cohort:$cohort[0],files:$files[0]}' > "$5"
        ;;
    verify)
        [[ $# == 3 ]] || aq_die 'Usage: component-artifacts.sh verify ROOT MANIFEST'
        verify "$(realpath -m -s -- "$2")" "$3"
        ;;
    compose)
        [[ $# -ge 3 ]] || aq_die 'Usage: component-artifacts.sh compose DESTINATION ROOT=MANIFEST ...'
        destination=$(realpath -m -s -- "$2"); shift 2
        aq_empty_root "$destination"
        : > "$scratch/paths"
        first=true
        for pair in "$@"; do
            root=${pair%%=*}; manifest=${pair#*=}
            verify "$(realpath -m -s -- "$root")" "$manifest"
            jq -S '.cohort' "$manifest" > "$scratch/cohort"
            if $first; then cp "$scratch/cohort" "$scratch/first-cohort"; first=false
            else cmp -s "$scratch/cohort" "$scratch/first-cohort" || aq_die 'Release cohort mismatch'; fi
            jq -r '.files[].path' "$manifest" >> "$scratch/paths"
        done
        [[ -z $(sort "$scratch/paths" | uniq -d) ]] || aq_die 'Duplicate component ownership'
        # A symlink/file owned by one component cannot be a parent in another.
        for pair in "$@"; do
            while IFS= read -r name; do
                if awk -v parent="$name/" 'index($0,parent)==1 {found=1} END {exit !found}' "$scratch/paths"; then aq_die "Conflicting parent ownership: $name"; fi
            done < <(jq -r '.files[].path' "${pair#*=}")
        done
        for pair in "$@"; do cp -dr --preserve=mode,timestamps --no-preserve=ownership "${pair%%=*}/." "$destination/"; done
        ;;
    extract)
        [[ $# == 3 ]] || aq_die 'Usage: component-artifacts.sh extract ARCHIVE DESTINATION'
        destination=$(realpath -m -s -- "$3")
        # libarchive's secure extraction rejects traversal through symlinks.
        # Reject unsafe names, duplicate entries, hard links and special files first.
        bsdtar -tf "$2" > "$scratch/names"
        while IFS= read -r name; do safe_name "${name%/}" || aq_die "Unsafe archive path: $name"; done < "$scratch/names"
        [[ -z $(sed 's|/$||' "$scratch/names" | sort | uniq -d) ]] || aq_die 'Duplicate archive member'
        bsdtar -tvf "$2" > "$scratch/types"
        awk 'substr($0,1,1) !~ /[-dl]/ || / link to / {bad=1} END {exit bad}' "$scratch/types" || aq_die 'Unsupported archive member'
        aq_empty_root "$destination"
        bsdtar -xpf "$2" -C "$destination" --no-same-owner --safe-writes
        ;;
    *) aq_die 'Expected manifest, verify, compose or extract';;
esac
