#!/bin/sh
set -eu

unset LD_PRELOAD

for tool in jq wlr-randr; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "SKIP: $tool is required" >&2
        exit 77
    }
done

if [ -n "${AQUEOUSCTL_BIN:-}" ]; then
    ctl=$AQUEOUSCTL_BIN
elif [ -x ./zig-out/bin/aqueousctl ]; then
    ctl=./zig-out/bin/aqueousctl
elif [ -x compositor/zig-out/bin/aqueousctl ]; then
    ctl=compositor/zig-out/bin/aqueousctl
else
    ctl=aqueousctl
fi

command -v "$ctl" >/dev/null 2>&1 || [ -x "$ctl" ] || {
    echo "FAIL: aqueousctl was not found" >&2
    exit 1
}

test_dir=$(mktemp -d /tmp/aqueousctl-outputs.XXXXXX)
trap 'rm -rf -- "$test_dir"' EXIT HUP INT TERM

"$ctl" outputs --json >"$test_dir/aqueousctl.json"
wlr-randr --json >"$test_dir/wlr-randr.json"
"$ctl" outputs >"$test_dir/aqueousctl.txt"

normalize='map({
    name,
    description,
    make,
    model,
    serial,
    physical_size,
    enabled,
    modes: (.modes | map({
        width,
        height,
        refresh_mhz: (.refresh * 1000 | round),
        preferred,
        current
    })),
    position: (.position // {x: 0, y: 0}),
    transform: (.transform // "normal"),
    scale_units: ((.scale // 1) * 256 | round),
    adaptive_sync: (.adaptive_sync // false)
}) | sort_by(.name)'

jq -S "$normalize" "$test_dir/aqueousctl.json" >"$test_dir/aqueousctl.normalized.json"
jq -S "$normalize" "$test_dir/wlr-randr.json" >"$test_dir/wlr-randr.normalized.json"

if ! cmp -s "$test_dir/aqueousctl.normalized.json" "$test_dir/wlr-randr.normalized.json"; then
    diff -u "$test_dir/wlr-randr.normalized.json" "$test_dir/aqueousctl.normalized.json" >&2 || true
    echo "FAIL: aqueousctl output information differs from wlr-randr" >&2
    exit 1
fi

for label in 'Enabled:' 'Modes:' 'Position:' 'Transform:' 'Scale:' 'Adaptive Sync:'; do
    grep -F "$label" "$test_dir/aqueousctl.txt" >/dev/null || {
        echo "FAIL: human output is missing $label" >&2
        exit 1
    }
done

echo "PASS: aqueousctl outputs matches wlr-randr information"
