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
assert manifest["plugin_api"] == 9
assert manifest["widget"][0]["entry"] == "widget.luau"
assert manifest["panel"][0]["entry"] == "panel.luau"
assert manifest["panel"][0]["placement"] == "attached"
assert manifest["panel"][0]["open_near_click"] is True
assert "aqueous-config" in manifest["dependencies"]

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
):
    assert key in translations, key

for entry in ("widget.luau", "panel.luau"):
    text = (root / entry).read_text()
    assert "import Qt" not in text
    assert "Quickshell" not in text

panel = (root / "panel.luau").read_text()
for feature in (
    "ui.dragSource",
    "ui.dropZone",
    "noctalia.outputs()",
    "monitor_changes",
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
