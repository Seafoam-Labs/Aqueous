#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
seam="$here/scripts/test-vulkan-render-seam.sh"
threshold=${AQUEOUS_VULKAN_BLUR_REFERENCE_TOLERANCE:-0.0002}

die() { echo "FAIL: $*" >&2; exit 1; }

[ "$#" -le 1 ] || die "usage: $0 [OUTPUT_DIRECTORY]"
if [ "$#" -eq 1 ]; then
    output=$(readlink -m "$1")
    mkdir -p "$output"
    [ -z "$(find "$output" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
        die "output directory is not empty: $output"
else
    output=$(mktemp -d /tmp/aqueous-vulkan-effects.XXXXXX)
fi

cached="$output/cached"
uncached="$output/uncached"
mkdir -p "$cached" "$uncached"

env AQUEOUS_VULKAN_BLUR_UNCACHED=0 "$seam" "$cached"
env AQUEOUS_VULKAN_BLUR_UNCACHED=1 "$seam" "$uncached"

comparisons="$output/comparisons.txt"
: >"$comparisons"
for name in \
    blur-static.png \
    blur-motion.png \
    blur-before-localized.png \
    blur-after-localized.png \
    after-buffer-reuse.png \
    blur-overlap.png \
    workspace-animation-before.png \
    workspace-animation-outgoing.png \
    workspace-animation-incoming.png \
    workspace-animation-after.png \
    before-output-resume.png \
    after-output-resume.png; do
    difference=$(
        magick \
            "$cached/$name" \
            "$uncached/$name" \
            -compose difference -composite \
            -alpha off -format '%[fx:mean]' info:
    )
    awk -v difference="$difference" -v threshold="$threshold" \
        'BEGIN { exit !(difference <= threshold) }' ||
        die "$name exceeds the uncached-reference tolerance: $difference"
    printf '%s=%s\n' "$name" "$difference" >>"$comparisons"
done

printf 'tolerance=%s\n' "$threshold" >>"$comparisons"
echo "PASS: cached blur matches the uncached reference within $threshold"
echo "artifacts: $output"
