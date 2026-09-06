#!/usr/bin/env python3
"""Stage each DMS source package with fixture binaries and verify its DMS session."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib
import xml.etree.ElementTree as ET


repo = Path(__file__).resolve().parents[2]
variants = (
    "PKGBUILD",
    "PKGBUILD-git",
    "GitPKGBUILD/PKGBUILD",
    "PKGBUILD-intel",
    "IntelPKGBUILD/PKGBUILD",
    "PKGBUILD-DMS",
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
        "aqueous-plugin-dist/bin/aqueous-config",
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
                '[[ " ${depends[*]} " == *" dms-aqueous "* ]]\n'
                '[[ " ${checkdepends[*]-} " == *" gsettings-desktop-schemas "* ]]\n'
                '[[ " ${depends[*]} ${checkdepends[*]-} ${optdepends[*]} " != *noctalia* ]]\n'
                'package',
                "test-dms-git-packaging", str(repo / variant),
            ],
            env={**os.environ, "srcdir": str(source), "pkgdir": str(stage)},
            check=True,
        )
        units = stage / "usr/lib/systemd/user"
        if variant == "GitPKGBUILD/PKGBUILD":
            assert (units / "graphical-session.target.wants/dms.service").readlink() == Path("../dms.service")
            # The dependency owns the unit; Aqueous only owns its enablement.
            assert not (units / "dms.service").exists()
            assert not (units / "aqueous-dms.service").exists()
            assert not (units / "graphical-session.target.wants/aqueous-dms.service").is_symlink()
        else:
            assert (units / "graphical-session.target.wants/aqueous-dms.service").readlink() == Path("../aqueous-dms.service")
            assert "ExecStart=/usr/bin/dms run --session" in (units / "aqueous-dms.service").read_text()
            assert not (units / "graphical-session.target.wants/dms.service").is_symlink()
        assert not any("noctalia" in str(p.relative_to(stage)).lower() for p in stage.rglob("*"))
        assert not (stage / "usr/bin/aqueous-welcome").exists()
        assert not (stage / "etc/xdg/autostart/org.aqueous.Welcome.desktop").exists()

        menu_path = stage / "etc/xdg/menus/aqueous-applications.menu"
        assert menu_path.read_bytes() == (repo / "packaging/menus/aqueous-applications.menu").read_bytes()
        menu = ET.parse(menu_path).getroot()
        assert menu.tag == "Menu" and menu.findtext("Name") == "Applications"
        for element in ("DefaultAppDirs", "DefaultDirectoryDirs", "Include/All"):
            assert menu.find(element) is not None

        for plugin_id in ("aqueousSettings", "aqueousPortal"):
            runtime = Path("usr/share/aqueous/dms-plugins") / plugin_id
            manifest = json.loads((stage / runtime / "plugin.json").read_text())
            assert manifest["id"] == plugin_id
            link = stage / "etc/xdg/quickshell/dms-plugins" / plugin_id
            assert str(link.readlink()) == "/" + str(runtime)
            components = manifest.get("components", {"daemon": manifest.get("component")})
            for component in components.values():
                assert (stage / runtime / component).is_file()

        assert (stage / "etc/xdg/xdg-desktop-portal-aqueous/config").read_bytes() == (repo / "packaging/portal/dms.conf").read_bytes()
        for executable in ("usr/bin/aqueous-config", "usr/lib/aqueous/aqueous-dms-portal-chooser"):
            assert os.access(stage / executable, os.X_OK)

        defaults = stage / "usr/share/aqueous/wm.toml"
        assert defaults.read_bytes() == (stage / "etc/xdg/aqueous/wm.toml").read_bytes()
        assert "noctalia" not in defaults.read_text().lower()
        config = tomllib.loads(defaults.read_text())
        assert config["actions"]["toggle_start_menu"] == "dms ipc call spotlight toggle"
        assert config["actions"]["screenshot"] == "dms screenshot region"
        assert config["keybinds"]["custom"]["Super+Shift+S"] == "spawn:dms screenshot region"
        print(f"{variant}: DMS dependency, session, plugins, portal and bindings passed")

    relocated = work / "relocated"
    subprocess.run(
        ["sh", str(repo / "packaging/install-dms-wm-config.sh")],
        env={**os.environ, "DESTDIR": str(relocated), "PREFIX": "/opt/aqueous", "SYSCONFDIR": "/etc"},
        check=True,
    )
    assert (relocated / "opt/aqueous/share/aqueous/wm.toml").read_bytes() == (relocated / "etc/xdg/aqueous/wm.toml").read_bytes()
    print("DMS default configuration relocation passed")
