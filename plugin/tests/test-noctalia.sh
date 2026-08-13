#!/usr/bin/env bash
set -euo pipefail
unset LD_PRELOAD

plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repo_root=$(cd "$plugin_root/.." && pwd)
default_config="$repo_root/packaging/noctalia/config.toml"

validation_config=$(mktemp)
trap 'rm -f "$validation_config"' EXIT

python3 - "$default_config" "$validation_config" "$plugin_root" <<'PY'
from pathlib import Path
import sys
import tomllib

config_path = Path(sys.argv[1])
validation_path = Path(sys.argv[2])
plugin_root = sys.argv[3]
text = config_path.read_text(encoding="utf-8")
config = tomllib.loads(text)

assert "aqueous/settings" in config["plugins"]["enabled"]
sources = {source["name"]: source for source in config["plugins"]["source"]}
assert [source["name"] for source in config["plugins"]["source"]] == [
    "official",
    "community",
    "aqueous",
]
assert sources["official"] == {
    "name": "official",
    "kind": "git",
    "location": "https://github.com/noctalia-dev/official-plugins",
}
assert sources["community"] == {
    "name": "community",
    "kind": "git",
    "location": "https://github.com/noctalia-dev/community-plugins",
}
assert any(
    source.get("name") == "aqueous"
    and source.get("kind") == "path"
    and source.get("location") == "/usr/share/aqueous/noctalia-plugins"
    for source in config["plugins"]["source"]
)
assert config["bar"]["default"]["start"] == [
    "launcher",
    "wallpaper",
    "workspaces",
    "aqueous_settings",
]
assert config["widget"]["aqueous_settings"]["type"] == "aqueous/settings:widget"

# Validate against the repository's plugin catalog instead of requiring the
# package-owned /usr/share path to exist in a source checkout or build root.
validation_path.write_text(
    text.replace("/usr/share/aqueous/noctalia-plugins", plugin_root),
    encoding="utf-8",
)
PY

noctalia plugins lint "$plugin_root/settings"
noctalia config validate "$validation_config"

if [[ ${AQUEOUS_NOCTALIA_LIVE_TEST:-0} != 1 ]]; then
    echo "Noctalia plugin and default-config validation passed (set AQUEOUS_NOCTALIA_LIVE_TEST=1 for a live source test)"
    exit 0
fi

noctalia msg plugins source add aqueous-test path "$plugin_root"
noctalia msg plugins enable aqueous/settings

enabled=0
for _ in $(seq 1 50); do
    if noctalia msg plugins list | rg -q '^aqueous/settings .* enabled(?: |$)'; then
        enabled=1
        break
    fi
    sleep 0.1
done
if [[ $enabled != 1 ]]; then
    echo "Aqueous plugin was discovered but did not finish enabling" >&2
    exit 1
fi

noctalia msg panel-toggle aqueous/settings:panel

echo "Noctalia live source test passed; the settings panel was toggled."
