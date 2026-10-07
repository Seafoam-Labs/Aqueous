#!/usr/bin/env python3
"""Check Shelly metadata and, optionally, archives from a --json build result."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
DEVARIO = ROOT / "packaging/devario"
NAMES = {
    "aqueous-core",
    "aqueous-session",
    "aqueous-integration-pearl",
    "aqueous-shell-pearl",
    "xdg-desktop-portal-aqueous",
}
ANY = {"aqueous-session", "aqueous-integration-pearl", "aqueous-shell-pearl"}


def run(*args):
    return subprocess.check_output(args, text=True)


def fields(text):
    result = {}
    for line in text.splitlines():
        if " = " in line and not line.startswith("#"):
            key, value = line.strip().split(" = ", 1)
            result.setdefault(key, []).append(value)
    return result


def metadata(directory):
    generated = run("shelly", "build", "--makesrcinfo", "--reviewed", str(directory / "PKGBUILD"))
    assert generated == (directory / ".SRCINFO").read_text(), f"Stale SRCINFO: {directory}"
    base, *members = generated.split("\npkgname = ")
    shared = fields(base)
    packages = {}
    for member in members:
        overrides = fields("pkgname = " + member)
        packages[overrides["pkgname"][0]] = shared | overrides
    return shared, packages


def check_metadata():
    base, packages = metadata(DEVARIO / "aqueous-devario")
    assert base["pkgbase"] == ["aqueous-devario"]
    assert set(packages) == NAMES
    assert "depends" not in base, "Sibling/runtime dependencies must not become shared build inputs"
    for dependency in base["makedepends"] + base["checkdepends"]:
        assert not dependency.startswith(("aqueous", "pearl", "xdg-desktop-portal-aqueous"))
    version = base["pkgver"][0] + "-" + base["pkgrel"][0]
    for name, package in packages.items():
        assert package["arch"] == (["any"] if name in ANY else ["x86_64", "aarch64"])
        assert not any("welcome" in dep or "noctalia" in dep or "dms" in dep
                       for dep in package.get("depends", []))
    assert f"aqueous-core={version}" in packages["aqueous-session"]["depends"]
    assert packages["aqueous-integration-pearl"]["depends"] == [f"aqueous-session={version}"]
    assert packages["aqueous-shell-pearl"]["depends"] == [f"aqueous-integration-pearl={version}", "pearl"]
    _, desktop = metadata(DEVARIO)
    assert set(desktop) == {"devario-desktop"}
    assert set(desktop["devario-desktop"]["depends"]) == {f"{name}={version}" for name in NAMES} | {"pearl", "pearl-greeter"}
    assert desktop["devario-desktop"]["backup"] == ["etc/xdg/aqueous/session.toml"]
    return packages, version


def check_archives(report_path, packages, version):
    report = json.loads(Path(report_path).read_text())
    assert report["success"] and report["packageBase"] == "aqueous-devario"
    artifacts = report["artifacts"]
    assert len(artifacts) == 5 and {a["packageName"] for a in artifacts} == NAMES
    required = {
        "aqueous-core": {"usr/bin/aqueous", "usr/bin/aqueousctl", "usr/bin/aqueous-config",
                         "usr/bin/aqueous-activity-launch", "usr/lib/aqueous/libwlroots-0.20.so",
                         "usr/share/man/man1/aqueousctl.1"},
        "aqueous-session": {"usr/share/wayland-sessions/aqueous.desktop", "usr/lib/aqueous/session-runtime.sh",
                            "etc/xdg/aqueous/wm.toml", "etc/xdg/xdg-desktop-portal-aqueous/config"},
        "aqueous-integration-pearl": {"usr/lib/systemd/user/aqueous-pearl.service"},
        "aqueous-shell-pearl": set(),
        "xdg-desktop-portal-aqueous": {"usr/bin/aqueous-portal-picker",
                                       "usr/lib/aqueous/xdg-desktop-portal-aqueous",
                                       "usr/share/xdg-desktop-portal/portals/aqueous.portal"},
    }
    owners = {}
    for artifact in artifacts:
        name, archive = artifact["packageName"], artifact["path"]
        members = run("bsdtar", "-tf", archive).splitlines()
        entries = {entry.removeprefix("./"): entry for entry in members}
        info = fields(run("bsdtar", "-xOf", archive, entries[".PKGINFO"]))
        assert info["pkgname"] == [name] and info["pkgbase"] == ["aqueous-devario"]
        assert info["pkgver"] == [version]
        assert info["arch"][0] in packages[name]["arch"]
        for archive_key, recipe_key in [("depend", "depends"), ("conflict", "conflicts"),
                                        ("provides", "provides"), ("license", "license"), ("backup", "backup")]:
            assert set(info.get(archive_key, [])) == set(packages[name].get(recipe_key, [])), (name, archive_key)
        payload = {entry for entry in entries if not entry.startswith(".") and not entry.endswith("/")}
        assert required[name] <= payload, (name, required[name] - payload)
        assert "etc/xdg/aqueous/session.toml" not in payload, "The desktop preset owns shell selection"
        assert not any("aqueous-welcome" in entry or "aqueous-dms" in entry or "aqueous-noctalia" in entry
                       for entry in payload)
        if name == "aqueous-shell-pearl":
            assert not payload
        for entry in payload:
            assert entry not in owners, (entry, owners.get(entry), name)
            owners[entry] = name
        if name == "aqueous-core":
            with tempfile.TemporaryDirectory(prefix="aqueous-runpath-") as temporary:
                binary = Path(temporary) / "aqueous"
                binary.write_bytes(subprocess.check_output(["bsdtar", "-xOf", archive, entries["usr/bin/aqueous"]]))
                assert run("patchelf", "--print-rpath", str(binary)).strip() == "$ORIGIN/../lib/aqueous"
    print("All five Shelly archives passed metadata, ownership and RUNPATH checks")


if __name__ == "__main__":
    if len(sys.argv) > 2:
        sys.exit(f"Usage: {sys.argv[0]} [shelly-build-result.json]")
    packages, version = check_metadata()
    print("Devario Shelly metadata checks passed")
    if len(sys.argv) == 2:
        check_archives(sys.argv[1], packages, version)
