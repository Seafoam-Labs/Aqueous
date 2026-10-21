#!/usr/bin/env python3
"""Check Shelly metadata and, optionally, archives from a --json build result."""
import hashlib
import json
import re
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
    "devario-desktop",
}
ANY = {"aqueous-session", "aqueous-integration-pearl", "aqueous-shell-pearl", "devario-desktop"}


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
    if directory.name == "aqueous-git":
        # Shelly refreshes VCS sources when generating metadata. Compare the
        # checked-in snapshot offline; a release worker can refresh with Shelly.
        generated = subprocess.check_output(["makepkg", "--printsrcinfo"], cwd=directory, text=True)
    else:
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
    base, packages = metadata(DEVARIO / "aqueous-desktop")
    assert base["pkgbase"] == ["aqueous-desktop"]
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
    assert packages["aqueous-shell-pearl"]["depends"] == ["pearl-capture-picker>=1", f"xdg-desktop-portal-aqueous={version}", f"aqueous-integration-pearl={version}", "pearl"]
    desktop = packages
    assert set(desktop["devario-desktop"]["depends"]) == {f"{name}>={version}" for name in NAMES - {"devario-desktop"}} | {"pearl", "pearl-greeter", "rtkit"}
    assert desktop["devario-desktop"]["backup"] == ["etc/xdg/aqueous/session.toml"]
    assert "install" not in desktop["devario-desktop"]
    minimal_base, minimal = metadata(DEVARIO / "aqueous")
    assert set(minimal) == {"aqueous"}
    assert minimal_base["pkgver"] == base["pkgver"]
    assert "aqueous-core" in minimal["aqueous"]["conflicts"]
    assert minimal["aqueous"]["provides"] == [f"aqueous={base['pkgver'][0]}"]
    git_base, git = metadata(DEVARIO / "aqueous-git")
    git_names = {name + "-git" for name in NAMES - {"devario-desktop"}} | {"aqueous-git"}
    assert set(git) == git_names
    git_version = git_base["pkgver"][0] + "-" + git_base["pkgrel"][0]
    assert set(git["aqueous-git"]["depends"]) == {
        f"{name}={git_version}" for name in git_names - {"aqueous-git"}
    } | {"pearl-git", "pearl-greeter"}
    assert git["aqueous-git"]["backup"] == ["etc/xdg/aqueous-git/session.toml"]
    assert "provides" not in git["aqueous-core-git"]
    assert "conflicts" not in git["aqueous-core-git"]
    for recipe_base, outputs in ((base, packages), (minimal_base, minimal), (git_base, git)):
        assert "zig=0.16.0" in recipe_base["makedepends"]
        assert "patchelf" in recipe_base["makedepends"]
        assert not any(dep.startswith(("aqueous", "pearl", "xdg-desktop-portal-aqueous"))
                       for dep in recipe_base["makedepends"] + recipe_base.get("checkdepends", []))
        full_version = recipe_base["pkgver"][0] + "-" + recipe_base["pkgrel"][0]
        for name, package in outputs.items():
            for dependency in package.get("depends", []):
                assert not any(shell in dependency for shell in ("welcome", "dms", "noctalia"))
                target = re.split(r"[<>=]", dependency)[0]
                if target in outputs:
                    operator = ">=" if name == "devario-desktop" else "="
                    assert dependency == f"{target}{operator}{full_version}"
    for directory in (DEVARIO / "aqueous-desktop", DEVARIO / "aqueous-git"):
        recipe_base = base if directory.name == "aqueous-desktop" else git_base
        index = recipe_base["source"].index("session.toml")
        assert hashlib.sha256((directory / "session.toml").read_bytes()).hexdigest() == recipe_base["sha256sums"][index]
    return packages, version


def check_presets():
    # Exercise actual package functions: each preset owns only its own config.
    with tempfile.TemporaryDirectory(prefix="aqueous-devario-presets-") as temporary:
        for recipe, name, instance in (("aqueous-desktop", "devario-desktop", "aqueous"),
                                       ("aqueous-git", "aqueous-git", "aqueous-git")):
            directory = DEVARIO / recipe
            destination = Path(temporary) / recipe
            subprocess.run(["bash", "-c", 'set -eu; source "$1"; srcdir=$2; pkgdir=$3; "package_$4"',
                            "_", str(directory / "PKGBUILD"), str(directory), str(destination), name], check=True)
            files = {str(p.relative_to(destination)) for p in destination.rglob("*") if p.is_file()}
            target = f"etc/xdg/{instance}/session.toml"
            assert files == {target}
            assert (destination / target).read_text() == 'version = 1\nshell = "pearl"\n'


def check_archives(report_path, packages, version):
    report = json.loads(Path(report_path).read_text())
    assert report["success"] and report["packageBase"] == "aqueous-desktop"
    artifacts = report["artifacts"]
    assert len(artifacts) == 6 and {a["packageName"] for a in artifacts} == NAMES
    required = {
        "devario-desktop": {"etc/xdg/aqueous/session.toml"},
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
        assert info["pkgname"] == [name] and info["pkgbase"] == ["aqueous-desktop"]
        assert info["pkgver"] == [version]
        assert info["arch"][0] in packages[name]["arch"]
        for archive_key, recipe_key in [("depend", "depends"), ("conflict", "conflicts"),
                                        ("provides", "provides"), ("license", "license"), ("backup", "backup")]:
            assert set(info.get(archive_key, [])) == set(packages[name].get(recipe_key, [])), (name, archive_key)
        payload = {entry for entry in entries if not entry.startswith(".") and not entry.endswith("/")}
        assert required[name] <= payload, (name, required[name] - payload)
        if name != "devario-desktop":
            assert "etc/xdg/aqueous/session.toml" not in payload, "The desktop preset owns shell selection"
        else:
            assert payload == required[name]
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
    print("All six Shelly archives passed metadata, ownership and RUNPATH checks")


if __name__ == "__main__":
    if len(sys.argv) > 2:
        sys.exit(f"Usage: {sys.argv[0]} [shelly-build-result.json]")
    packages, version = check_metadata()
    check_presets()
    print("Devario metadata and preset ownership checks passed")
    if len(sys.argv) == 2:
        check_archives(sys.argv[1], packages, version)
