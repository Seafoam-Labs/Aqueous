#!/usr/bin/env bash
set -euo pipefail
unset LD_PRELOAD

# glib2 provides gsettings, but its desktop interface schema is packaged
# separately. Without it, toolkit synchronization fails in clean build roots.
if command -v gsettings >/dev/null 2>&1 &&
    ! GSETTINGS_BACKEND=memory gsettings list-keys org.gnome.desktop.interface >/dev/null 2>&1; then
    echo "aqueous-config tests require the org.gnome.desktop.interface schema; install gsettings-desktop-schemas and check GSETTINGS_SCHEMA_DIR/XDG_DATA_DIRS" >&2
    exit 1
fi

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
    'case "$2" in' \
    '  *style*) printf "%b\n" "Test Sans\tRegular\t80\t0\t100" "Test Sans\tSemiBold Italic\t180\t100\t100" "Test Sans\tCondensed Black\t210\t110\t75" ;;' \
    '  *) printf "%s\n" "Zed Sans" "Alpha Sans" "zed sans" "Bad, Alternate" "" ;;' \
    'esac' \
    >"$test_root/bin/fc-list"
chmod +x "$test_root/bin/fc-list"

run_helper() {
    env \
        HOME="$test_root/home" \
        XDG_CONFIG_HOME="$test_root/config" \
        XDG_STATE_HOME="$test_root/state" \
        NOCTALIA_STATE_HOME="$test_root/state" \
        GSETTINGS_BACKEND=memory \
        XCURSOR_PATH="$test_root/icons" \
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
  .helper_version == "0.7.1" and
  (.fields | length) >= 145 and
  (.fields[] | select(.id == "layout.default") | .options | index("composable") != null and index("stacking") != null and index("float") == null) and
  (.fields[] | select(.id == "layout.options.float.placement") | .value == "minimal-overlap" and .configured_section == "layout.options.stacking") and
  (.fields[] | select(.id == "layout.options.scrolling.prefer_vertical_on_portrait") | .value == true and .file == "layout") and
  (.fields[] | select(.id == "layout.border_focused") | .type == "color" and .value == "0xFF88C0D0") and
  (.fields[] | select(.id == "snap_center") | .value == []) and
  (.fields[] | select(.id == "grow_floating_to_edge_right") | .value == []) and
  (.fields[] | select(.id == "spawn_terminal") | .value == ["Super+Return", "Super+T"]) and
  (.fields[] | select(.id == "reload_rules") | .value == ["Super+Shift+R"]) and
  (.fields[] | select(.id == "display.apply_on_reload") | .value == true and .inherited == true and .file == "outputs") and
  (.custom_keybinds | length) == 2 and
  (.custom_keybinds[] | select(.chord == "Super+E") | .command == "spawn:nemo") and
  (.snap_zones[] | select(.id == "a") | .complete == true and .width > 0.66) and
  .default_snap_layout == "work" and
  (.snap_layouts[] | select(.id == "work") | .name == "Work" and .padding == 8 and (.zones | length) == 2) and
  (.snap_layouts[] | select(.id == "work") | .zones[] | select(.id == "terminal") | .complete == true) and
  (.window_rules[] | select(.values.title == "Dialog #1 = ready") | .values.layout == "stacking" and .values.stack_layer == "above") and
  (.monitors | length) == 2 and
  (.monitors[] | select(.name == "DP-1") | .x == 0 and .transform == "normal") and
  .desktop_typography.families == ["Alpha Sans", "monospace", "sans-serif", "serif", "Zed Sans"] and
  .desktop_cursor.managed == false and
  .desktop_cursor.theme == "default" and
  .desktop_cursor.size == 24 and
  (.desktop_cursor.themes | index("default") != null) and
  (.desktop_cursor.targets[] | select(.id == "uwsm") | .state == "unmanaged") and
  (.desktop_typography.faces[] | select(.family == "Test Sans" and .style == "SemiBold Italic") | .weight == 600 and .slant == "italic" and .width == "normal") and
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

invalid_color_request="$test_root/invalid-color-request.json"
jq -n \
    --arg generation "$generation" \
    '{
      protocol: 1,
      expected_generation: $generation,
      changes: [{id: "layout.border_focused", value: "#80112233"}]
    }' >"$invalid_color_request"
if run_helper validate --request "$invalid_color_request" >"$test_root/invalid-color-response.json"; then
    echo "eight-digit picker color unexpectedly validated" >&2
    exit 1
fi
jq -e '.ok == false and .code == "invalid_value"' "$test_root/invalid-color-response.json" >/dev/null
rg -q '^border_focused = 0xFF88C0D0$' "$config_root/layout.toml"

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
        {id: "layout.border_focused", value: "0x4088c0d0"},
        {id: "layout.options.float.placement", value: "center"},
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
jq -e '
  .ok == true and
  .generation != "'"$generation"'" and
  (.fields[] | select(.id == "layout.border_focused") | .value == "0x4088C0D0")
' "$applied" >/dev/null

rg -q '^# fixture comment must survive$' "$config_root/wm.toml"
rg -q '^enabled = false # keep inline$' "$config_root/wm.toml"
rg -q '^apply_on_reload = true$' "$config_root/wm.toml"
rg -q '^apply_on_reload = false$' "$config_root/outputs.toml"
rg -q '^gaps_outer = 18$' "$config_root/layout.toml"
rg -q '^border_focused = 0x4088C0D0$' "$config_root/layout.toml"
rg -q '^border_normal = 0xFF3B4252$' "$config_root/layout.toml"
rg -q '^border_urgent = 0xFFBF616A$' "$config_root/layout.toml"
rg -q '^placement = "center"$' "$config_root/layout.toml"
test "$(rg -c '^\[layout\.options\.(float|floating|stack|stacking)\]$' "$config_root/layout.toml")" = 1
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
    --arg backups "$test_root/backups" \
    --arg custom_id "$custom_id" \
    '{
      protocol: 1,
      expected_generation: $generation,
      backup_dir: $backups,
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
custom_delete_id=$(jq -r '.custom_keybinds[] | select(.chord == "XF86AudioMute") | .id' "$test_root/custom-applied.json")
dialog_rule_id=$(jq -r '.window_rules[] | select(.values.title == "Dialog #1 = ready") | .id' "$test_root/custom-applied.json")
collections_request="$test_root/collections-request.json"
jq -n \
    --arg generation "$new_generation" \
    --arg backups "$test_root/backups" \
    --arg custom_delete_id "$custom_delete_id" \
    --arg dialog_rule_id "$dialog_rule_id" \
    '{
      protocol: 1,
      expected_generation: $generation,
      backup_dir: $backups,
      custom_keybind_changes: [
        {id: $custom_delete_id, op: "delete"},
        {id: "new:1", op: "add", chord: "Super+Alt+A", command: "builtin:snap_zone:a"}
      ],
      snap_zone_changes: [
        {id: "a", op: "update", x: 0.0, y: 0.0, width: 0.75, height: 1.0},
        {id: "b", op: "update", x: 0.75, y: 0.0, width: 0.25, height: 1.0}
      ],
      default_snap_layout: "focus",
      snap_layouts: [
        {id: "focus", name: "Focus", padding: 12, zones: [
          {id: "main", name: "Main", x: 0.0, y: 0.0, width: 0.7, height: 1.0},
          {id: "side", name: "Side", x: 0.7, y: 0.0, width: 0.3, height: 1.0}
        ]}
      ],
      window_rule_changes: [
        {id: $dialog_rule_id, op: "update", values: {placement_policy: "minimal-overlap", fixed_position: true}},
        {id: "new-rule:1", op: "add", values: {app_id: "org.example.Stack", layout: "stacking", stack_layer: "below", focus: false}}
      ]
    }' >"$collections_request"
run_helper apply --request "$collections_request" >"$test_root/collections-applied.json"
jq -e '
  (.custom_keybinds[] | select(.chord == "Super+Alt+A") | .command == "builtin:snap_zone:a") and
  ([.custom_keybinds[].chord] | index("XF86AudioMute") == null) and
  (.snap_zones[] | select(.id == "a") | .width == 0.75) and
  (.snap_zones[] | select(.id == "b") | .complete == true and .width == 0.25) and
  .default_snap_layout == "focus" and
  (.snap_layouts[] | select(.id == "focus") | .padding == 12 and (.zones | length) == 2) and
  (.window_rules[] | select(.values.title == "Dialog #1 = ready") | .values.fixed_position == true and .values.placement_policy == "minimal-overlap") and
  (.window_rules[] | select(.values.app_id == "org.example.Stack") | .values.layout == "stacking" and .values.stack_layer == "below" and .values.focus == false)
' "$test_root/collections-applied.json" >/dev/null
rg -Fq '"Super+Alt+A" = "builtin:snap_zone:a"' "$config_root/wm.toml"
! rg -q '^"XF86AudioMute"' "$config_root/wm.toml"
rg -q '^width = 0.75$' "$config_root/layout.toml"
rg -q '^app_id = "org.example.Stack"$' "$config_root/rules.toml"

new_generation=$(jq -r .generation "$test_root/collections-applied.json")
new_rule_id=$(jq -r '.window_rules[] | select(.values.app_id == "org.example.Stack") | .id' "$test_root/collections-applied.json")
move_rule_request="$test_root/move-rule-request.json"
jq -n --arg generation "$new_generation" --arg rule_id "$new_rule_id" '{protocol: 1, expected_generation: $generation, window_rule_changes: [{id: $rule_id, op: "move", direction: -1}]}' >"$move_rule_request"
run_helper apply --request "$move_rule_request" >"$test_root/rule-moved.json"
jq -e '([.window_rules[] | select(.values.app_id == "org.example.Stack") | .position][0]) < ([.window_rules[] | select(.values.title == "Dialog #1 = ready") | .position][0])' "$test_root/rule-moved.json" >/dev/null

new_generation=$(jq -r .generation "$test_root/rule-moved.json")
moved_rule_id=$(jq -r '.window_rules[] | select(.values.app_id == "org.example.Stack") | .id' "$test_root/rule-moved.json")
delete_collections_request="$test_root/delete-collections-request.json"
jq -n --arg generation "$new_generation" --arg backups "$test_root/backups" --arg rule_id "$moved_rule_id" '{protocol: 1, expected_generation: $generation, backup_dir: $backups, snap_zone_changes: [{id: "b", op: "delete"}], window_rule_changes: [{id: $rule_id, op: "delete"}]}' >"$delete_collections_request"
run_helper apply --request "$delete_collections_request" >"$test_root/collections-deleted.json"
jq -e '(.snap_zones[] | select(.id == "b") | .configured == false) and ([.window_rules[].values.app_id] | index("org.example.Stack") == null)' "$test_root/collections-deleted.json" >/dev/null

new_generation=$(jq -r .generation "$test_root/collections-deleted.json")
raw_request="$test_root/raw-request.json"
raw_source=$(jq -r .raw_files.rules "$test_root/collections-deleted.json")
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
        {id: "desktop.font.style", value: "SemiBold Italic"},
        {id: "desktop.font.weight", value: 600},
        {id: "desktop.font.slant", value: "italic"},
        {id: "desktop.font.width", value: "normal"},
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
  .desktop_typography.style == "SemiBold Italic" and
  .desktop_typography.weight == 600 and
  .desktop_typography.slant == "italic" and
  .desktop_typography.width == "normal" and
  .desktop_typography.size_pt == 14 and
  .desktop_typography.failed_count == 0 and
  (.desktop_typography.targets[] | select(.id == "noctalia") | .synced == false and .state == "partial") and
  (.desktop_typography.targets[] | select(.id == "gtk3") | .synced == true) and
  (.desktop_typography.targets[] | select(.id == "gtk4") | .synced == true) and
  (.desktop_typography.targets[] | select(.id == "qt5ct") | .synced == true) and
  (.desktop_typography.targets[] | select(.id == "qt6ct") | .synced == true)
' "$test_root/typography-applied.json" >/dev/null
rg -q '^family = "Test Sans"$' "$config_root/appearance.toml"
rg -q '^style = "SemiBold Italic"$' "$config_root/appearance.toml"
rg -q '^weight = 600$' "$config_root/appearance.toml"
rg -q '^slant = "italic"$' "$config_root/appearance.toml"
rg -q '^width = "normal"$' "$config_root/appearance.toml"
rg -q '^size_pt = 14$' "$config_root/appearance.toml"
rg -q '^font_family = "Test Sans"$' "$test_root/state/noctalia/settings.toml"
rg -q '^ui_scale = 1.166' "$test_root/state/noctalia/settings.toml"
rg -q '^font_scale = 1.166' "$test_root/state/noctalia/settings.toml"
rg -q '^gtk-font-name = Test Sans SemiBold Italic 14$' "$test_root/config/gtk-3.0/settings.ini"
rg -q '^gtk-font-name = Test Sans SemiBold Italic 14$' "$test_root/config/gtk-4.0/settings.ini"
rg -Fq 'general = "Test Sans,14,-1,5,63,1,0,0,0,0"' "$test_root/config/qt5ct/qt5ct.conf"
rg -Fq 'general = "Test Sans,14,-1,5,600,1,0,0,0,0,0,0,0,100,1"' "$test_root/config/qt6ct/qt6ct.conf"
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

missing_face_request="$test_root/missing-face.json"
jq -n \
    --arg generation "$typography_generation" \
    '{
      protocol: 1,
      expected_generation: $generation,
      changes: [{id: "desktop.font.style", value: "Missing Face"}],
      raw_files: {}
    }' >"$missing_face_request"
if run_helper validate --request "$missing_face_request" >"$test_root/missing-face-response.json"; then
    echo "missing exact font face unexpectedly validated" >&2
    exit 1
fi
jq -e '.ok == false and .code == "invalid_value"' "$test_root/missing-face-response.json" >/dev/null

# Cursor settings remain unmanaged until explicitly enabled. Validation is
# side-effect free; Apply updates the live compositor, activation environment,
# GTK files, and the helper-owned UWSM drop-in.
mkdir -p "$test_root/icons/Space Theme/cursors"
printf '%s\n' \
    '#!/bin/sh' \
    'state=${CURSOR_TEST_STATE:?}' \
    'log=${CURSOR_TEST_LOG:?}' \
    'if [ "$2" = set ]; then printf "%s|%s\n" "$4" "$6" >"$state"; printf "%s\n" "$*" >>"$log"; fi' \
    'IFS="|" read -r theme size <"$state"' \
    'printf "{\"ok\":true,\"status\":\"success\",\"theme\":\"%s\",\"size\":%s}\n" "$theme" "$size"' \
    >"$test_root/bin/aqueousctl"
chmod +x "$test_root/bin/aqueousctl"
printf '%s\n' 'default|24' >"$test_root/cursor-state"
printf '%s\n' \
    '#!/bin/sh' \
    'log=${CURSOR_TEST_LOG:?}' \
    'envfile=${CURSOR_TEST_ENV:?}' \
    'if [ "$2" = show-environment ]; then [ ! -f "$envfile" ] || cat "$envfile"; exit 0; fi' \
    'printf "%s\n" "$*" >>"$log"' \
    'printf "%s\n%s\n" "$3" "$4" >"$envfile"' \
    >"$test_root/bin/systemctl"
chmod +x "$test_root/bin/systemctl"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >>"${CURSOR_TEST_LOG:?}"' '[ "${CURSOR_TEST_FAIL_DBUS:-0}" != 1 ]' >"$test_root/bin/dbus-update-activation-environment"
chmod +x "$test_root/bin/dbus-update-activation-environment"
printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s\n" "$*" >>"${CURSOR_TEST_LOG:?}"' \
    'if [ "$1" = get ]; then case "$3" in cursor-theme) printf "'"'"'Space Theme'"'"'\n" ;; cursor-size) printf "32\n" ;; *) printf "'"'"'Test Sans 14'"'"'\n" ;; esac; fi' \
    >"$test_root/bin/gsettings"
chmod +x "$test_root/bin/gsettings"
export CURSOR_TEST_STATE="$test_root/cursor-state"
export CURSOR_TEST_LOG="$test_root/cursor-commands.log"
export CURSOR_TEST_ENV="$test_root/activation-environment"
: >"$CURSOR_TEST_LOG"

cursor_snapshot="$test_root/cursor-snapshot.json"
run_helper snapshot --json >"$cursor_snapshot"
jq -e '
  .desktop_cursor.effective_theme == "default" and
  .desktop_cursor.effective_size == 24 and
  (.desktop_cursor.themes | index("Space Theme") != null)
' "$cursor_snapshot" >/dev/null
cursor_generation=$(jq -r .generation "$cursor_snapshot")
cursor_request="$test_root/cursor-request.json"
jq -n --arg generation "$cursor_generation" '{
  protocol: 1,
  expected_generation: $generation,
  changes: [
    {id: "desktop.cursor.managed", value: true},
    {id: "desktop.cursor.theme", value: "Space Theme"},
    {id: "desktop.cursor.size", value: 32}
  ]
}' >"$cursor_request"
run_helper validate --request "$cursor_request" >"$test_root/cursor-validated.json"
test ! -e "$test_root/config/uwsm/env-aqueous.d/90-aqueous-cursor"
! rg -q 'cursor set|set-environment|^set .*cursor-theme' "$CURSOR_TEST_LOG"

run_helper apply --request "$cursor_request" >"$test_root/cursor-applied.json"
jq -e '
  .desktop_cursor.managed == true and
  .desktop_cursor.theme == "Space Theme" and
  .desktop_cursor.size == 32 and
  .desktop_cursor.failed_count == 0 and
  ([.desktop_cursor.targets[] | select(.available == true and .synced != true)] | length) == 0
' "$test_root/cursor-applied.json" >/dev/null
rg -Fq "export XCURSOR_THEME='Space Theme'" "$test_root/config/uwsm/env-aqueous.d/90-aqueous-cursor"
rg -Fq "export XCURSOR_SIZE='32'" "$test_root/config/uwsm/env-aqueous.d/90-aqueous-cursor"
rg -Fq 'cursor set --theme Space Theme --size 32 --json' "$CURSOR_TEST_LOG"
rg -Fq -- '--user set-environment XCURSOR_THEME=Space Theme XCURSOR_SIZE=32' "$CURSOR_TEST_LOG"
rg -Fq -- '--systemd XCURSOR_THEME=Space Theme XCURSOR_SIZE=32' "$CURSOR_TEST_LOG"
! rg -q '^set .*font-name' "$CURSOR_TEST_LOG"
rg -q '^gtk-cursor-theme-name = Space Theme$' "$test_root/config/gtk-3.0/settings.ini"
rg -q '^gtk-cursor-theme-size = 32$' "$test_root/config/gtk-4.0/settings.ini"
run_helper snapshot --json >"$test_root/cursor-resnapshot.json"
jq -e '([.desktop_cursor.targets[] | select(.available == true and .synced != true)] | length) == 0' "$test_root/cursor-resnapshot.json" >/dev/null

cursor_generation=$(jq -r .generation "$test_root/cursor-resnapshot.json")
jq -n --arg generation "$cursor_generation" '{protocol: 1, expected_generation: $generation, changes: [{id: "desktop.cursor.theme", value: "Missing Theme"}]}' >"$test_root/missing-cursor-request.json"
if run_helper validate --request "$test_root/missing-cursor-request.json" >"$test_root/missing-cursor-response.json"; then
    echo "missing cursor theme unexpectedly validated" >&2
    exit 1
fi
jq -e '.ok == false and .code == "invalid_value"' "$test_root/missing-cursor-response.json" >/dev/null

printf '%s\n' 'default|24' >"$test_root/cursor-state"
run_helper snapshot --json >"$test_root/cursor-drifted.json"
jq -e '(.desktop_cursor.targets[] | select(.id == "aqueous") | .state == "drifted")' "$test_root/cursor-drifted.json" >/dev/null
cursor_generation=$(jq -r .generation "$test_root/cursor-drifted.json")
jq -n --arg generation "$cursor_generation" '{protocol: 1, expected_generation: $generation, sync_cursor: true}' >"$test_root/cursor-retry-request.json"
run_helper apply --request "$test_root/cursor-retry-request.json" >"$test_root/cursor-retried.json"
test "$(cat "$test_root/cursor-state")" = 'Space Theme|32'
test "$(jq -r .generation "$test_root/cursor-retried.json")" = "$cursor_generation"

export CURSOR_TEST_FAIL_DBUS=1
cursor_generation=$(jq -r .generation "$test_root/cursor-retried.json")
jq -n --arg generation "$cursor_generation" '{protocol: 1, expected_generation: $generation, changes: [{id: "desktop.cursor.size", value: 36}]}' >"$test_root/cursor-partial-request.json"
run_helper apply --request "$test_root/cursor-partial-request.json" >"$test_root/cursor-partial.json"
jq -e '.desktop_cursor.size == 36 and .desktop_cursor.failed_count == 1 and (.desktop_cursor.targets[] | select(.id == "activation") | .state == "failed")' "$test_root/cursor-partial.json" >/dev/null
rg -q '^size = 36$' "$config_root/appearance.toml"
unset CURSOR_TEST_FAIL_DBUS

cursor_generation=$(jq -r .generation "$test_root/cursor-partial.json")
jq -n --arg generation "$cursor_generation" '{protocol: 1, expected_generation: $generation, changes: [{id: "desktop.cursor.managed", value: false}]}' >"$cursor_request"
run_helper apply --request "$cursor_request" >"$test_root/cursor-disabled.json"
test ! -e "$test_root/config/uwsm/env-aqueous.d/90-aqueous-cursor"
jq -e '.desktop_cursor.managed == false and (.desktop_cursor.targets[] | select(.id == "uwsm") | .synced == true)' "$test_root/cursor-disabled.json" >/dev/null

# Alias conflicts are reported and can be explicitly normalized without losing
# unknown keys. Merely editing a legacy section never creates a duplicate.
printf '%s\n' '' '[layout.options.float]' 'placement = "under-pointer"' 'future_option = "preserve-me"' >>"$config_root/layout.toml"
alias_snapshot="$test_root/alias-snapshot.json"
run_helper snapshot --json >"$alias_snapshot"
jq -e '
  .stacking_alias_count == 2 and
  (.fields[] | select(.id == "layout.options.float.placement") | .value == "under-pointer" and .configured_section == "layout.options.float") and
  (.warnings | map(select(contains("Multiple stacking option aliases"))) | length == 1)
' "$alias_snapshot" >/dev/null
alias_generation=$(jq -r .generation "$alias_snapshot")
normalize_request="$test_root/normalize-request.json"
jq -n --arg generation "$alias_generation" '{protocol: 1, expected_generation: $generation, normalize_stacking: true}' >"$normalize_request"
run_helper apply --request "$normalize_request" >"$test_root/normalized.json"
jq -e '.stacking_alias_count == 1 and (.fields[] | select(.id == "layout.options.float.placement") | .value == "under-pointer" and .configured_section == "layout.options.stacking")' "$test_root/normalized.json" >/dev/null
test "$(rg -c '^\[layout\.options\.stacking\]$' "$config_root/layout.toml")" = 1
! rg -q '^\[layout\.options\.float\]$' "$config_root/layout.toml"
rg -q '^future_option = "preserve-me"$' "$config_root/layout.toml"

sed -i 's/^\[layout\.options\.stacking\]$/[layout.options.float]/' "$config_root/layout.toml"
legacy_snapshot="$test_root/legacy-snapshot.json"
run_helper snapshot --json >"$legacy_snapshot"
legacy_generation=$(jq -r .generation "$legacy_snapshot")
jq -e '(.fields[] | select(.id == "layout.options.float.placement") | .configured_section == "layout.options.float")' "$legacy_snapshot" >/dev/null
legacy_request="$test_root/legacy-request.json"
jq -n --arg generation "$legacy_generation" '{protocol: 1, expected_generation: $generation, changes: [{id: "layout.options.float.placement", value: "center"}]}' >"$legacy_request"
run_helper apply --request "$legacy_request" >"$test_root/legacy-applied.json"
test "$(rg -c '^\[layout\.options\.(float|floating|stack|stacking)\]$' "$config_root/layout.toml")" = 1
rg -q '^\[layout\.options\.float\]$' "$config_root/layout.toml"
rg -q '^placement = "center"$' "$config_root/layout.toml"

legacy_generation=$(jq -r .generation "$test_root/legacy-applied.json")
invalid_collections_request="$test_root/invalid-collections-request.json"
jq -n --arg generation "$legacy_generation" '{protocol: 1, expected_generation: $generation, custom_keybind_changes: [{id: "new:duplicate", op: "add", chord: "Super+Return", command: "spawn:test"}]}' >"$invalid_collections_request"
if run_helper validate --request "$invalid_collections_request" >"$test_root/invalid-collections-response.json"; then
    echo "duplicate built-in chord unexpectedly validated" >&2
    exit 1
fi
jq -e '.ok == false and .code == "invalid_value"' "$test_root/invalid-collections-response.json" >/dev/null

jq -n --arg generation "$legacy_generation" '{protocol: 1, expected_generation: $generation, snap_zone_changes: [{id: "c", op: "update", x: 0, y: 0, width: 2, height: 1}]}' >"$invalid_collections_request"
if run_helper validate --request "$invalid_collections_request" >"$test_root/invalid-collections-response.json"; then
    echo "out-of-bounds snap zone unexpectedly validated" >&2
    exit 1
fi
jq -e '.ok == false and .code == "invalid_value"' "$test_root/invalid-collections-response.json" >/dev/null

jq -n --arg generation "$legacy_generation" '{protocol: 1, expected_generation: $generation, window_rule_changes: [{id: "new-rule:invalid", op: "add", values: {layout: "stacking"}}]}' >"$invalid_collections_request"
if run_helper validate --request "$invalid_collections_request" >"$test_root/invalid-collections-response.json"; then
    echo "matcher-free rule unexpectedly validated" >&2
    exit 1
fi
jq -e '.ok == false and .code == "invalid_value"' "$test_root/invalid-collections-response.json" >/dev/null

echo "aqueous-config integration tests passed"

python3 "$plugin_root/tests/test-modes.py" "$helper"
