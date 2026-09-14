#!/usr/bin/env python3
"""Stage source packages with fixture binaries and verify selectable desktop sessions."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib
import xml.etree.ElementTree as ET


repo = Path(__file__).resolve().parents[2]
variants = (
    "PKGBUILD-git",
    "GitPKGBUILD/PKGBUILD",
    "PKGBUILD-intel",
    "IntelPKGBUILD/PKGBUILD",
    "PKGBUILD-DMS",
    "gitNoctalia/PKGBUILD",
)

with tempfile.TemporaryDirectory(prefix="aqueous-git-packaging-") as temporary:
    work = Path(temporary)
    source = work / "src"
    source.mkdir()
    (source / "aqueous").symlink_to(repo, target_is_directory=True)
    # package() only copies these artifacts; building them is a separate check.
    for name in (
        "aqueous-dist/bin/aqueous",
        "aqueous-dist/bin/aqueousctl",
        "aqueous-dist/lib/aqueous/libwlroots-0.20.so",
        "aqueous-config-dist/bin/aqueous-config",
        "aqueous-welcome-dist/bin/aqueous-welcome",
        "aqueous-portal-dist/usr/lib/aqueous/xdg-desktop-portal-aqueous",
        "aqueous-portal-chooser-dist/bin/aqueous-dms-portal-chooser",
        "xdg-desktop-portal-wlr-0.8.4/LICENSE",
    ):
        artifact = source / name
        artifact.parent.mkdir(parents=True, exist_ok=True)
        artifact.write_text("packaging test fixture\n")
        artifact.chmod(0o755)

    for variant in variants:
        stage = work / variant.replace("/", "-")
        subprocess.run(
            [
                "bash", "-euc",
                'source "$1"\n'
                '[[ " ${depends[*]} " != *" dms-shell "* ]]\n'
                '[[ " ${depends[*]} " != *" noctalia "* ]]\n'
                '[[ " ${depends[*]} " != *" pearl "* ]]\n'
                '[[ " ${depends[*]} " != *" pearl-git "* ]]\n'
                'for dependency in gtk4 shelly sudo ghostty; do [[ " ${depends[*]} " == *" $dependency "* ]]; done\n'
                '[[ " ${depends[*]} " != *" dms-aqueous "* ]]\n'
                'package',
                "test-dms-git-packaging", str(repo / variant),
            ],
            env={**os.environ, "srcdir": str(source), "pkgdir": str(stage)},
            check=True,
        )
        units = stage / "usr/lib/systemd/user"
        for shell in ("pearl", "dms", "noctalia"):
            unit = f"aqueous-{shell}.service"
            assert (units / "graphical-session.target.wants" / unit).readlink() == Path("..") / unit
            assert f"aqueous-welcome --worker condition {shell}" in (units / unit).read_text()
            assert not (units / "graphical-session.target.wants" / f"{shell}.service").is_symlink()
            assert "external-condition" in (units / f"{shell}.service.d/50-aqueous-selection.conf").read_text()
        assert (stage / "usr/share/aqueous/noctalia/config.toml").is_file()
        assert not (stage / "usr/share/aqueous/settings-application").exists()
        assert (stage / "usr/bin/aqueous-config").exists()
        assert not (stage / "usr/share/aqueous/dms-plugins/aqueousSettings").exists()
        assert not (stage / "usr/bin/aqueous-settings").exists()
        assert not (stage / "usr/share/applications/org.aqueous.Settings.desktop").exists()
        assert (stage / "usr/bin/aqueous-welcome").exists()
        assert not (stage / "usr/lib/aqueous/welcome-setup.py").exists()
        assert (stage / "etc/xdg/autostart/org.aqueous.Welcome.desktop").exists()

        menu_path = stage / "etc/xdg/menus/aqueous-applications.menu"
        assert menu_path.read_bytes() == (repo / "packaging/menus/aqueous-applications.menu").read_bytes()
        menu = ET.parse(menu_path).getroot()
        assert menu.tag == "Menu" and menu.findtext("Name") == "Applications"
        for element in ("DefaultAppDirs", "DefaultDirectoryDirs", "Include/All"):
            assert menu.find(element) is not None

        for plugin_id in (() if variant == "gitNoctalia/PKGBUILD" else ("aqueousSettingsAppearance", "aqueousPortal")):
            runtime = Path("usr/share/aqueous/dms-plugins") / plugin_id
            manifest = json.loads((stage / runtime / "plugin.json").read_text())
            assert manifest["id"] == plugin_id
            link = stage / "etc/xdg/quickshell/dms-plugins" / plugin_id
            assert str(link.readlink()) == "/" + str(runtime)
            components = manifest.get("components", {"daemon": manifest.get("component")})
            for component in components.values():
                assert (stage / runtime / component).is_file()

        assert "aqueous-shell-action chooser" in (stage / "etc/xdg/xdg-desktop-portal-aqueous/config").read_text()
        for executable in ("usr/bin/aqueous-config", "usr/bin/aqueous-welcome", "usr/bin/aqueous-shell-action"):
            assert os.access(stage / executable, os.X_OK)

        defaults = stage / "usr/share/aqueous/wm.toml"
        assert defaults.read_bytes() == (stage / "etc/xdg/aqueous/wm.toml").read_bytes()
        config = tomllib.loads(defaults.read_text())
        assert config["actions"]["toggle_start_menu"] == "aqueous-shell-action launcher"
        assert config["actions"]["screenshot"] == "aqueous-shell-action screenshot"
        assert config["keybinds"]["custom"]["Super+Shift+S"] == "spawn:aqueous-shell-action screenshot"
        print(f"{variant}: shell-neutral dependencies, GTK welcome, conditional sessions, portal and bindings passed")

    relocated = work / "relocated"
    subprocess.run(
        ["sh", str(repo / "packaging/install-dms-wm-config.sh")],
        env={**os.environ, "DESTDIR": str(relocated), "PREFIX": "/opt/aqueous", "SYSCONFDIR": "/etc"},
        check=True,
    )
    assert (relocated / "opt/aqueous/share/aqueous/wm.toml").read_bytes() == (relocated / "etc/xdg/aqueous/wm.toml").read_bytes()
    print("DMS default configuration relocation passed")
