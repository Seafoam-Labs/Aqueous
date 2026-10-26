#!/usr/bin/env python3
"""Check Arch's stable Pearl package metadata, upgrade path and staged session."""

import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib


ROOT = Path(__file__).resolve().parents[2]
FOLDER = ROOT / "packaging/arch/aqueous-desktop"
RECIPE = FOLDER / "PKGBUILD"
base, packages = {}, {}
section = base
for line in (FOLDER / ".SRCINFO").read_text().splitlines():
    if " = " not in line:
        continue
    key, value = line.strip().split(" = ", 1)
    if key == "pkgname":
        section = packages.setdefault(value, {})
    else:
        section.setdefault(key, []).append(value)

# Evaluate metadata without running build/staging tools or requiring makepkg.
fields = "pkgbase pkgdesc pkgver pkgrel url arch license checkdepends makedepends options source sha256sums depends provides conflicts replaces backup install".split()
evaluate = r'''
set -euo pipefail
source "$1"
if [[ $2 == base ]]; then
    printf 'pkgname\t%s\n' "${pkgname[@]}"
else
    bash() { :; }
    install() { :; }
    patchelf() {
        if [[ $1 == --print-rpath ]]; then printf '%s\n' '$ORIGIN/../lib/aqueous'; fi
    }
    srcdir=/unused pkgdir=/unused
    "package_$2"
fi
shift 2
for field in "$@"; do
    if declare -p "$field" &>/dev/null; then
        declare -n value="$field"
        for item in "${value[@]}"; do printf '%s\t%s\n' "$field" "$item"; done
    fi
done
'''
for name in ["base", *packages]:
    output = subprocess.check_output(
        ["bash", "-c", evaluate, "_", str(RECIPE), name, *fields], text=True
    )
    actual = {}
    for line in output.splitlines():
        key, value = line.split("\t", 1)
        actual.setdefault(key, []).append(value)
    if name == "base":
        assert actual.pop("pkgname") == list(packages)
        expected = base
    else:
        expected = base | packages[name]
        assert name not in actual.get("conflicts", [])
    assert actual == expected, f"Stale .SRCINFO for {name}"

assert set(packages) == {
    "aqueous-core", "aqueous-session", "aqueous-integration-pearl",
    "aqueous-shell-pearl", "xdg-desktop-portal-aqueous", "aqueous-desktop",
}
version = base["pkgver"][0] + "-" + base["pkgrel"][0]
for name, info in packages.items():
    for dependency in info.get("depends", []):
        assert not dependency.startswith("devario-")
        target = dependency.split(">")[0].split("=")[0]
        if target in packages:
            operator = ">=" if name == "aqueous-desktop" else "="
            assert dependency == f"{target}{operator}{version}"

desktop = packages["aqueous-desktop"]
assert {"pearl", "pearl-greeter", "rtkit"} <= set(desktop["depends"])
assert "pearl-capture-picker>=1" in packages["aqueous-shell-pearl"]["depends"]
retired = {
    "aqueous-welcome", "aqueous-shell-none", "aqueous-integration-dms",
    "aqueous-integration-noctalia", "aqueous-shell-dms", "aqueous-shell-noctalia",
}
assert set(desktop["replaces"]) == retired
assert retired <= set(desktop["conflicts"])
assert desktop["backup"] == ["etc/xdg/aqueous/session.toml"]
assert base["sha256sums"][0] in ("SKIP", hashlib.sha256((FOLDER / "session.toml").read_bytes()).hexdigest())

with tempfile.TemporaryDirectory(prefix="aqueous-arch-pearl-") as temporary:
    work = Path(temporary)
    (work / "aqueous").symlink_to(ROOT, target_is_directory=True)
    (work / "session.toml").write_bytes((FOLDER / "session.toml").read_bytes())
    for name in (
        "aqueous-picker-dist/bin/aqueous-portal-picker",
        "aqueous-portal-dist/usr/lib/aqueous/xdg-desktop-portal-aqueous",
        "xdg-desktop-portal-wlr-0.8.4/LICENSE",
    ):
        artifact = work / name
        artifact.parent.mkdir(parents=True, exist_ok=True)
        artifact.write_text("packaging test fixture\n")
    # Core's compiled binaries and ELF patching are covered by the build checks.
    for name in packages.keys() - {"aqueous-core"}:
        subprocess.run(
            ["bash", "-c", 'set -euo pipefail; source "$1"; srcdir=$2; pkgdir=$3; "package_$4"',
             "_", str(RECIPE), temporary, str(work / name), name], check=True,
        )
    units = work / "aqueous-integration-pearl/usr/lib/systemd/user"
    assert "ExecStart=/usr/bin/aqueous-activity-launch /usr/bin/pearl\n" in (units / "aqueous-pearl.service").read_text()
    assert (units / "graphical-session.target.wants/aqueous-pearl.service").readlink() == Path("../aqueous-pearl.service")
    assert (units / "pearl.service.d/50-aqueous-selection.conf").is_file()
    selection = work / "aqueous-desktop/etc/xdg/aqueous/session.toml"
    assert tomllib.loads(selection.read_text()) == {"version": 1, "shell": "pearl"}
    runtime = work / "aqueous-session/usr/lib/aqueous/session-runtime.sh"
    env = dict(os.environ, XDG_CONFIG_HOME=str(work / "user-config"),
               AQUEOUS_SYSCONFDIR=str(work / "aqueous-desktop/etc"))
    assert subprocess.check_output(["bash", str(runtime), "selection"], env=env, text=True).strip() == "pearl"
    user_selection = work / "user-config/aqueous/session.toml"
    user_selection.parent.mkdir(parents=True)
    user_selection.write_text('version = 1\nshell = "none"\n')
    assert subprocess.check_output(["bash", str(runtime), "selection"], env=env, text=True).strip() == "none"
    portal = work / "xdg-desktop-portal-aqueous"
    assert os.access(portal / "usr/bin/aqueous-portal-picker", os.X_OK)
    assert (portal / "usr/lib/aqueous/xdg-desktop-portal-aqueous").is_file()
    assert (portal / "usr/share/xdg-desktop-portal/portals/aqueous.portal").is_file()
    for name in packages.keys() - {"aqueous-core"}:
        assert not (work / name / "usr/bin/aqueous-welcome").exists()
        assert not (work / name / "etc/xdg/autostart/org.aqueous.Welcome.desktop").exists()

print("PASS: Arch Pearl metadata, upgrade replacements, staging, portal picker and session defaults")
