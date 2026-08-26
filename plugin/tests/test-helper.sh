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
mkdir -p "$test_root/bin"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$3"' >"$test_root/bin/fc-match"
chmod +x "$test_root/bin/fc-match"
printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s\n" "Zed Sans" "Alpha Sans" "zed sans" "Bad, Alternate" ""' \
    >"$test_root/bin/fc-list"
chmod +x "$test_root/bin/fc-list"

run_helper() {
    env \
        HOME="$test_root/home" \
        XDG_CONFIG_HOME="$test_root/config" \
        XDG_STATE_HOME="$test_root/state" \
        NOCTALIA_STATE_HOME="$test_root/state" \
        GSETTINGS_BACKEND=memory \
        PATH="$test_root/bin:$PATH" \
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
  (.fields[] | select(.id == "layout.options.scrolling.prefer_vertical_on_portrait") | .value == true and .file == "layout") and
  (.fields[] | select(.id == "spawn_terminal") | .value == ["Super+Return", "Super+T"]) and
  (.fields[] | select(.id == "reload_rules") | .value == ["Super+Shift+R"]) and
  (.fields[] | select(.id == "display.apply_on_reload") | .value == true and .inherited == true and .file == "outputs") and
  (.custom_keybinds | length) == 2 and
  (.custom_keybinds[] | select(.chord == "Super+E") | .command == "spawn:nemo") and
  (.monitors | length) == 2 and
  (.monitors[] | select(.name == "DP-1") | .x == 0 and .transform == "normal") and
  .desktop_typography.families == ["Alpha Sans", "monospace", "sans-serif", "serif", "Zed Sans"] and
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
        {id: "layout.options.scrolling.prefer_vertical_on_portrait", value: false},
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
rg -q '^prefer_vertical_on_portrait = false$' "$config_root/layout.toml"
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

# Desktop typography is canonicalized in appearance.toml and synchronized to
# Noctalia's final settings layer plus the available toolkit configuration.
mkdir -p "$test_root/config/qt5ct" "$test_root/config/qt6ct"
printf '%s\n' '[Appearance]' 'style=Fusion' >"$test_root/config/qt5ct/qt5ct.conf"
printf '%s\n' '[Appearance]' 'style=Fusion' >"$test_root/config/qt6ct/qt6ct.conf"
typography_snapshot="$test_root/typography-snapshot.json"
run_helper snapshot --json >"$typography_snapshot"
typography_generation=$(jq -r .generation "$typography_snapshot")
typography_request="$test_root/typography-request.json"
jq -n \
    --arg generation "$typography_generation" \
    '{
      protocol: 1,
      expected_generation: $generation,
      changes: [
        {id: "desktop.font.family", value: "Test Sans"},
        {id: "desktop.font.size_pt", value: 14}
      ],
      raw_files: {}
    }' >"$typography_request"
if ! run_helper apply --request "$typography_request" >"$test_root/typography-applied.json"; then
    cat "$test_root/typography-applied.json" >&2
    exit 1
fi
jq -e '
  .desktop_typography.family == "Test Sans" and
  (.desktop_typography.families | index("Test Sans") != null) and
  .desktop_typography.size_pt == 14 and
  (.desktop_typography.targets[] | select(.id == "noctalia") | .synced == true) and
  (.desktop_typography.targets[] | select(.id == "gtk3") | .synced == true) and
  (.desktop_typography.targets[] | select(.id == "gtk4") | .synced == true) and
  (.desktop_typography.targets[] | select(.id == "qt5ct") | .synced == true) and
  (.desktop_typography.targets[] | select(.id == "qt6ct") | .synced == true)
' "$test_root/typography-applied.json" >/dev/null
rg -q '^family = "Test Sans"$' "$config_root/appearance.toml"
rg -q '^size_pt = 14$' "$config_root/appearance.toml"
rg -q '^font_family = "Test Sans"$' "$test_root/state/noctalia/settings.toml"
rg -q '^ui_scale = 1.166' "$test_root/state/noctalia/settings.toml"
rg -q '^font_scale = 1.166' "$test_root/state/noctalia/settings.toml"
rg -q '^gtk-font-name = Test Sans 14$' "$test_root/config/gtk-3.0/settings.ini"
rg -q '^gtk-font-name = Test Sans 14$' "$test_root/config/gtk-4.0/settings.ini"
rg -Fq 'general = "Test Sans,14,-1,5,50,0,0,0,0,0"' "$test_root/config/qt5ct/qt5ct.conf"
rg -Fq 'general = "Test Sans,14,-1,5,400,0,0,0,0,0,0,0,0,0,1"' "$test_root/config/qt6ct/qt6ct.conf"
rg -q '^style=Fusion$' "$test_root/config/qt5ct/qt5ct.conf"

invalid_font_request="$test_root/invalid-font.json"
typography_generation=$(jq -r .generation "$test_root/typography-applied.json")
jq -n \
    --arg generation "$typography_generation" \
    '{
      protocol: 1,
      expected_generation: $generation,
      changes: [{id: "desktop.font.family", value: "Bad, Alternate"}],
      raw_files: {}
    }' >"$invalid_font_request"
if run_helper validate --request "$invalid_font_request" >"$test_root/invalid-font-response.json"; then
    echo "ambiguous Qt font family unexpectedly validated" >&2
    exit 1
fi
jq -e '.ok == false and .code == "invalid_value"' "$test_root/invalid-font-response.json" >/dev/null

echo "aqueous-config integration tests passed"
