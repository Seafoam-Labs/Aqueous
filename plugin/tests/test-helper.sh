#!/usr/bin/env bash
set -euo pipefail
unset LD_PRELOAD

plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
helper=${1:-"$plugin_root/helper/zig-out/bin/aqueous-config"}
test_root=$(mktemp -d /tmp/aqueous-config-test.XXXXXX)
trap 'rm -rf "$test_root"' EXIT

config_root="$test_root/config/aqueous"
mkdir -p "$config_root"
cp "$plugin_root/tests/fixtures/"*.toml "$config_root/"

run_helper() {
    env \
        HOME="$test_root/home" \
        XDG_CONFIG_HOME="$test_root/config" \
        AQUEOUS_CONFIG="$config_root/wm.toml" \
        AQUEOUS_OUTPUTS="$config_root/outputs.toml" \
        AQUEOUS_LAYOUT="$config_root/layout.toml" \
        AQUEOUS_INPUT="$config_root/input.toml" \
        AQUEOUS_RULES="$config_root/rules.toml" \
        "$helper" "$@"
}

snapshot="$test_root/snapshot.json"
run_helper snapshot --json >"$snapshot"
jq -e '
  .ok == true and
  .protocol == 1 and
  (.fields | length) >= 130 and
  (.fields[] | select(.id == "layout.default") | .options | index("composable") != null) and
  (.fields[] | select(.id == "spawn_terminal") | .value == ["Super+Return", "Super+T"]) and
  (.fields[] | select(.id == "reload_rules") | .value == ["Super+Shift+R"]) and
  (.fields[] | select(.id == "display.apply_on_reload") | .value == true and .inherited == true and .file == "outputs") and
  (.custom_keybinds | length) == 2 and
  (.custom_keybinds[] | select(.chord == "Super+E") | .command == "spawn:nemo") and
  (.monitors | length) == 2 and
  (.monitors[] | select(.name == "DP-1") | .x == 0 and .transform == "normal") and
  .files.wm.path != "" and
  (.raw_files.wm | contains("fixture comment"))
' "$snapshot" >/dev/null

generation=$(jq -r .generation "$snapshot")

# Noctalia encodes empty Luau tables as JSON objects. Older panel builds sent
# these members unconditionally, so keep the helper compatible with that
# representation while still rejecting populated objects.
empty_table_request="$test_root/empty-table-request.json"
jq -n \
    --arg generation "$generation" \
    '{
      protocol: 1,
      expected_generation: $generation,
      changes: {},
      raw_files: {},
      monitor_changes: {},
      custom_keybind_changes: {}
    }' >"$empty_table_request"
run_helper validate --request "$empty_table_request" |
    jq -e '.ok == true and .generation == "'"$generation"'"' >/dev/null

request="$test_root/request.json"
jq -n \
    --arg generation "$generation" \
    --arg backups "$test_root/backups" \
    '{
      protocol: 1,
      expected_generation: $generation,
      backup_dir: $backups,
      create_user_override: true,
      changes: [
        {id: "blur.enabled", value: false},
        {id: "display.apply_on_reload", value: false},
        {id: "layout.gaps_outer", value: 18},
        {id: "input.touchpad.tap", value: false},
        {id: "spawn_terminal", value: "Super+Return, Super+Enter"}
      ],
      raw_files: {}
    }' >"$request"

validated="$test_root/validated.json"
run_helper validate --request "$request" >"$validated"
jq -e '.ok == true and .generation != "'"$generation"'"' "$validated" >/dev/null

applied="$test_root/applied.json"
run_helper apply --request "$request" >"$applied"
jq -e '.ok == true and .generation != "'"$generation"'"' "$applied" >/dev/null

rg -q '^# fixture comment must survive$' "$config_root/wm.toml"
rg -q '^enabled = false # keep inline$' "$config_root/wm.toml"
rg -q '^apply_on_reload = true$' "$config_root/wm.toml"
rg -q '^apply_on_reload = false$' "$config_root/outputs.toml"
rg -q '^gaps_outer = 18$' "$config_root/layout.toml"
rg -q '^tap = false$' "$config_root/input.toml"
rg -Fq 'spawn_terminal = ["Super+Return", "Super+Enter"]' "$config_root/wm.toml"
test -f "$test_root/backups/$generation/wm.toml"
test -f "$test_root/backups/$generation/layout.toml"
test -f "$test_root/backups/$generation/input.toml"
test -f "$test_root/backups/$generation/outputs.toml"

if run_helper apply --request "$request" >"$test_root/stale.json"; then
    echo "stale generation unexpectedly applied" >&2
    exit 1
fi
jq -e '.ok == false and .code == "external_change"' "$test_root/stale.json" >/dev/null

monitor_generation=$(jq -r .generation "$applied")
monitor_id=$(jq -r '.monitors[] | select(.name == "DP-1") | .id' "$applied")
monitor_request="$test_root/monitor-request.json"
jq -n \
    --arg generation "$monitor_generation" \
    --arg monitor_id "$monitor_id" \
    '{
      protocol: 1,
      expected_generation: $generation,
      changes: [],
      raw_files: {},
      monitor_changes: [
        {id: $monitor_id, name: "DP-1", x: -1440, y: 200, transform: "90"},
        {id: "live:DP-9", name: "DP-9", x: 0, y: 0, transform: "270"}
      ]
    }' >"$monitor_request"
run_helper apply --request "$monitor_request" >"$test_root/monitor-applied.json"
jq -e '
  (.monitors[] | select(.name == "DP-1") | .x == -1440 and .y == 200 and .transform == "90") and
  (.monitors[] | select(.name == "DP-9") | .x == 0 and .transform == "270")
' "$test_root/monitor-applied.json" >/dev/null
rg -q '^position = \[-1440, 200\]$' "$config_root/outputs.toml"
rg -q '^transform = "90"$' "$config_root/outputs.toml"
rg -q '^name = "DP-9"$' "$config_root/outputs.toml"
rg -q '^position = \[0, 0\]$' "$config_root/wm.toml"

new_generation=$(jq -r .generation "$test_root/monitor-applied.json")
custom_id=$(jq -r '.custom_keybinds[] | select(.chord == "Super+E") | .id' "$test_root/monitor-applied.json")
custom_request="$test_root/custom-request.json"
jq -n \
    --arg generation "$new_generation" \
    --arg custom_id "$custom_id" \
    '{
      protocol: 1,
      expected_generation: $generation,
      changes: [
        {id: "set_layout_primary", value: "Super+P"}
      ],
      raw_files: {},
      custom_keybind_changes: [
        {id: $custom_id, chord: "Super+F", command: "spawn:thunar"}
      ]
    }' >"$custom_request"
run_helper apply --request "$custom_request" >"$test_root/custom-applied.json"
jq -e '
  (.custom_keybinds[] | select(.chord == "Super+F") | .command == "spawn:thunar")
' "$test_root/custom-applied.json" >/dev/null
rg -Fq '"Super+F" = "spawn:thunar"' "$config_root/wm.toml"
rg -Fq 'set_layout_primary = ["Super+P"]' "$config_root/wm.toml"

new_generation=$(jq -r .generation "$test_root/custom-applied.json")
raw_request="$test_root/raw-request.json"
raw_source=$(jq -r .raw_files.rules "$test_root/custom-applied.json")
jq -n \
    --arg generation "$new_generation" \
    --arg backups "$test_root/backups" \
    --arg rules "$raw_source"$'\n# raw editor addition' \
    '{
      protocol: 1,
      expected_generation: $generation,
      backup_dir: $backups,
      create_user_override: true,
      changes: [],
      raw_files: {rules: $rules}
    }' >"$raw_request"
run_helper apply --request "$raw_request" >"$test_root/raw-applied.json"
rg -q '^# raw editor addition$' "$config_root/rules.toml"

invalid_request="$test_root/invalid.json"
final_generation=$(jq -r .generation "$test_root/raw-applied.json")
jq -n \
    --arg generation "$final_generation" \
    '{
      protocol: 1,
      expected_generation: $generation,
      changes: [{id: "opacity.value", value: 4.0}],
      raw_files: {}
    }' >"$invalid_request"
if run_helper validate --request "$invalid_request" >"$test_root/invalid-response.json"; then
    echo "out-of-range value unexpectedly validated" >&2
    exit 1
fi
jq -e '.ok == false and .code == "invalid_value"' "$test_root/invalid-response.json" >/dev/null

echo "aqueous-config integration tests passed"
