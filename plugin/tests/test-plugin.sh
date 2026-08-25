#!/usr/bin/env bash
set -euo pipefail
unset LD_PRELOAD

plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runtime="$plugin_root/settings"

python3 - "$runtime" <<'PY'
import json
import pathlib
import sys
import tomllib

root = pathlib.Path(sys.argv[1])
manifest = tomllib.loads((root / "plugin.toml").read_text())
assert manifest["id"] == "aqueous/settings"
assert manifest["min_noctalia"] == "5.0.0"
assert manifest["plugin_api"] == 9
assert manifest["widget"][0]["entry"] == "widget.luau"
assert manifest["panel"][0]["entry"] == "panel.luau"
assert manifest["panel"][0]["placement"] == "attached"
assert manifest["panel"][0]["open_near_click"] is True
assert "aqueous-config" in manifest["dependencies"]
assert "aqueousctl" in manifest["dependencies"]

logo = root / "aqueous.png"
assert logo.is_file()
assert logo.read_bytes().startswith(b"\x89PNG\r\n\x1a\n")

translations = json.loads((root / "translations/en.json").read_text())
for key in (
    "title",
    "widget.tooltip",
    "settings.helper_path.label",
    "settings.helper_path.description",
    "action.apply",
    "error.external_change",
    "display.drag_hint",
    "display.rotation",
    "keybind.builtin",
    "keybind.custom",
    "overview.workspace_layout",
    "overview.workspace_layout.changed",
):
    assert key in translations, key

for entry in ("widget.luau", "panel.luau"):
    text = (root / entry).read_text()
    assert "import Qt" not in text
    assert "Quickshell" not in text

widget = (root / "widget.luau").read_text()
assert 'barWidget.setImage("aqueous.png")' in widget
assert 'barWidget.setText("Aqueous")' not in widget
assert 'barWidget.outputName()' in widget
assert 'noctalia.state.set("panel_output"' in widget

panel = (root / "panel.luau").read_text()
for feature in (
    "ui.dragSource",
    "ui.dropZone",
    "noctalia.outputs()",
    "monitor_changes",
    "custom_keybind_changes",
    "keybindsView",
    'field.category == "keybinds" and 1',
    'noctalia.state.get("panel_output")',
    'layout --output ',
    'setWorkspaceLayout',
    'ui.select',
    'return ui.row({ align = "center", justify = "start" }, {',
):
    assert feature in panel, feature
PY

python3 - "$plugin_root/catalog.toml" <<'PY'
import pathlib
import sys
import tomllib

catalog = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
assert catalog["plugin"][0]["id"] == "aqueous/settings"
assert catalog["plugin"][0]["plugin_api"] == 9
PY

noctalia plugins lint "$runtime"
echo "Noctalia plugin validation passed"
