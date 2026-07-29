#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
single="$here/scripts/test-vulkan-dwindle-blur-domain.sh"
threshold=${AQUEOUS_VULKAN_BLUR_REFERENCE_TOLERANCE:-0.0002}

die() { echo "FAIL: $*" >&2; exit 1; }

[ "$#" -le 1 ] || die "usage: $0 [OUTPUT_DIRECTORY]"
if [ "$#" -eq 1 ]; then
    output=$(readlink -m "$1")
    mkdir -p "$output"
    [ -z "$(find "$output" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
        die "output directory is not empty: $output"
else
    output=$(mktemp -d /tmp/aqueous-vulkan-dwindle-blur-effects.XXXXXX)
fi

cached="$output/cached"
uncached="$output/uncached"
mkdir -p "$cached" "$uncached"

cached_status=0
uncached_status=0
env AQUEOUS_VULKAN_BLUR_UNCACHED=0 "$single" "$cached" ||
    cached_status=$?
env AQUEOUS_VULKAN_BLUR_UNCACHED=1 "$single" "$uncached" ||
    uncached_status=$?

comparisons="$output/cached-vs-uncached.txt"
: >"$comparisons"
comparison_status=0
for name in \
    static-right.png \
    cache-hit.png \
    edge-incremental.png \
    edge-full.png \
    focus-left.png \
    focus-right-roundtrip.png; do
    if [ ! -s "$cached/$name" ] || [ ! -s "$uncached/$name" ]; then
        printf '%s=missing\n' "$name" >>"$comparisons"
        comparison_status=1
        continue
    fi
    difference=$(
        magick \
            "$cached/$name" \
            "$uncached/$name" \
            -compose difference -composite \
            -alpha off -format '%[fx:mean]' info:
    )
    printf '%s=%s\n' "$name" "$difference" >>"$comparisons"
    awk -v difference="$difference" -v limit="$threshold" \
        'BEGIN { exit !(difference <= limit) }' ||
        comparison_status=1
done
printf 'tolerance=%s\n' "$threshold" >>"$comparisons"

[ "$cached_status" -eq 0 ] ||
    die "cached run failed with status $cached_status (artifacts: $output)"
[ "$uncached_status" -eq 0 ] ||
    die "uncached run failed with status $uncached_status (artifacts: $output)"
[ "$comparison_status" -eq 0 ] ||
    die "cached output differs from uncached oracle (artifacts: $output)"

echo "PASS: cached and uncached dwindle blur-domain renders match"
echo "artifacts: $output"
