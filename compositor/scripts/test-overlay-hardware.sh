#!/usr/bin/env bash
set -euo pipefail

# Live DRM qualification helper. Start Aqueous with overlay planes enabled,
# launch the matched workload (for example Dota 2), then run this script from
# that session. It records time-series diagnostics and enforces counter/phase
# invariants without attempting to automate the game itself.

unset LD_PRELOAD

duration=${AQUEOUS_OVERLAY_DURATION:-7200}
interval=${AQUEOUS_OVERLAY_INTERVAL:-5}
vendor=${AQUEOUS_OVERLAY_VENDOR:-auto}
output_filter=${AQUEOUS_OVERLAY_OUTPUT:-}
ctl=${AQUEOUSCTL_BIN:-aqueousctl}
artifact_dir=${AQUEOUS_OVERLAY_ARTIFACT_DIR:-}

die() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*" >&2; exit 77; }
for tool in jq date; do command -v "$tool" >/dev/null 2>&1 || skip "$tool is required"; done
command -v "$ctl" >/dev/null 2>&1 || [ -x "$ctl" ] || die "aqueousctl was not found"
[[ "$duration" =~ ^[0-9]+$ ]] && [ "$duration" -gt 0 ] || die "AQUEOUS_OVERLAY_DURATION must be positive seconds"
[[ "$interval" =~ ^[0-9]+$ ]] && [ "$interval" -gt 0 ] || die "AQUEOUS_OVERLAY_INTERVAL must be positive seconds"

if [ "$vendor" = auto ]; then
    if command -v lspci >/dev/null 2>&1; then
        gpu=$(lspci -nnk 2>/dev/null | grep -A3 -Ei 'VGA compatible controller|3D controller' || true)
        if grep -qi nvidia <<<"$gpu"; then vendor=nvidia
        elif grep -Eqi 'AMD|ATI|amdgpu' <<<"$gpu"; then vendor=amd
        else vendor=unknown
        fi
    else
        vendor=unknown
    fi
fi
case "$vendor" in amd|nvidia|unknown) ;; *) die "vendor must be amd, nvidia, auto, or unknown" ;; esac

if [ -z "$artifact_dir" ]; then
    artifact_dir=$(mktemp -d "/tmp/aqueous-overlay-${vendor}.XXXXXX")
else
    mkdir -p "$artifact_dir"
fi
samples="$artifact_dir/overlay-samples.jsonl"
summary="$artifact_dir/summary.json"
kernel_before="$artifact_dir/kernel-before.log"
kernel_after="$artifact_dir/kernel-after.log"

if command -v journalctl >/dev/null 2>&1; then
    journalctl -k --no-pager --since '5 minutes ago' >"$kernel_before" 2>/dev/null || true
fi

initial=$($ctl overlay-planes --json)
if [ -n "$output_filter" ]; then
    jq -e --arg output "$output_filter" 'any(.[]; .output == $output)' <<<"$initial" >/dev/null ||
        die "output $output_filter is absent from overlay diagnostics"
    selector='map(select(.output == $output))'
else
    selector='.'
fi

jq -e --arg output "$output_filter" "${selector} | length > 0 and all(.[]; .enabled and .capability != \"unavailable\")" \
    <<<"$initial" >/dev/null || {
    jq . <<<"$initial" >&2
    die "overlay promotion is disabled or unavailable on the selected output"
}

start_epoch=$(date +%s)
end_epoch=$((start_epoch + duration))
echo "INFO: qualifying vendor=$vendor for ${duration}s; artifacts: $artifact_dir"
while [ "$(date +%s)" -lt "$end_epoch" ]; do
    now=$(date +%s)
    snapshot=$($ctl overlay-planes --json) || die "aqueousctl failed during soak"
    jq -c --argjson timestamp "$now" --arg output "$output_filter" \
        "${selector}[] | {timestamp:\$timestamp, vendor:\"$vendor\"} + ." \
        <<<"$snapshot" >>"$samples"
    sleep "$interval"
done

if command -v journalctl >/dev/null 2>&1; then
    journalctl -k --no-pager --since "@$start_epoch" >"$kernel_after" 2>/dev/null || true
fi

jq -s '
  group_by(.output) | map({
    output: .[0].output,
    samples: length,
    phases: (map(.phase) | unique),
    reasons: (map(.rejection_reason) | unique),
    attempts_delta: (.[-1].counters.attempts - .[0].counters.attempts),
    accepted_delta: (.[-1].counters.accepted - .[0].counters.accepted),
    rejected_delta: (.[-1].counters.rejected - .[0].counters.rejected),
    backoff_skips_delta: (.[-1].counters.backoff_skips - .[0].counters.backoff_skips),
    fallback_delta: (.[-1].counters.fallback_retries - .[0].counters.fallback_retries),
    promotions_delta: (.[-1].counters.promotions - .[0].counters.promotions),
    demotions_delta: (.[-1].counters.demotions - .[0].counters.demotions)
  })
' "$samples" >"$summary"

jq -e 'all(.[];
    .samples >= 2 and
    .fallback_delta == 0 and
    ((.phases | index("promoted")) != null or .accepted_delta > 0) and
    (.rejected_delta == 0 or .backoff_skips_delta > 0)
)' "$summary" >/dev/null || {
    cat "$summary" >&2
    die "hardware qualification invariants failed"
}

if [ -s "$kernel_after" ] && grep -Eqi 'drm.*(atomic|flip|commit).*(fail|error)|NVRM: Xid|amdgpu.*(reset|timeout|fault)' "$kernel_after"; then
    grep -Ei 'drm.*(atomic|flip|commit).*(fail|error)|NVRM: Xid|amdgpu.*(reset|timeout|fault)' "$kernel_after" >&2 || true
    die "kernel DRM/GPU errors were recorded during the soak"
fi

cat "$summary"
echo "PASS: $vendor overlay-plane soak; artifacts: $artifact_dir"
