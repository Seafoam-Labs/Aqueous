#!/usr/bin/env python3
"""Verify staged DMS units together using an offline systemd manager.

No services are started. Requires systemd-analyze and permission to create
systemd's local verification sockets (some sandboxes forbid those sockets).
"""
import os
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="aqueous-dms-units-") as directory:
    base = Path(directory)
    env = dict(os.environ, AQUEOUS_PORTAL_CHOOSER_BINARY="/usr/bin/true",
               AQUEOUS_WELCOME_BINARY="/usr/bin/true", PREFIX="/usr", SYSCONFDIR="/etc")
    sources = []
    for channel in ("git", "intel-git"):
        stage = base / channel
        subprocess.run(["bash", str(repo / "packaging/git/desktop-stage.sh"), channel, "integration-dms"],
                       env=dict(env, DESTDIR=str(stage)), check=True)
        sources.append((f"aqueous-{channel}-dms", stage / f"usr/lib/systemd/user/aqueous-{channel}-dms.service"))
    for name, installer, args in (
        ("aqueous-dms", "stage-component.sh", ["integration-dms"]),
        ("aqueous-legacy-dms", "install-welcome.sh", []),
    ):
        stage = base / name
        subprocess.run(["bash", str(repo / "packaging" / installer), *args],
                       env=dict(env, DESTDIR=str(stage)), check=True)
        sources.append((name, stage / "usr/lib/systemd/user/aqueous-dms.service"))
    sources.append(("aqueous-template-dms", repo / "packaging/aqueous-dms.service"))
    units = base / "units"
    units.mkdir()
    # Keep service type and bus registrations verbatim from the shipped units.
    # The minimal bodies avoid needing installed desktop executables, session
    # targets, or the user's actual unit directories for this load-time test.
    for name, source in sources:
        directives = [line for line in source.read_text().splitlines()
                      if line.startswith(("Type=", "BusName="))]
        assert "Type=exec" in directives, source
        assert not any(line.startswith("BusName=") for line in directives), source
        (units / f"{name}.service").write_text(
            "[Service]\n" + "\n".join(directives) + "\nExecStart=/usr/bin/true\n")
    upstream = units / "dms.service"
    upstream.write_text("[Service]\nType=dbus\nBusName=org.freedesktop.Notifications\nExecStart=/usr/bin/true\n")

    def verify(paths):
        return subprocess.run(["systemd-analyze", "--user", "--generators=false", "verify", *map(str, paths)],
                              capture_output=True, text=True, timeout=30)

    # Negative control: reproduce the exact reported failure with the old unit.
    old = units / "aqueous-old-dms.service"
    old.write_text(upstream.read_text())
    result = verify([upstream, old])
    assert result.returncode != 0 and "Two services allocated for the same bus name" in result.stderr, result.stderr
    # Check the full unit edit offered to installed users. An empty BusName=
    # in a drop-in is rejected by systemd and cannot clear the vendor value.
    old.write_text(old.read_text().replace("Type=dbus", "Type=exec").replace(
        "BusName=org.freedesktop.Notifications\n", ""))
    result = verify([upstream, old])
    assert result.returncode == 0, result.stderr
    old.unlink()
    result = verify([upstream, *(units / f"{name}.service" for name, _ in sources)])
    assert result.returncode == 0, result.stderr
print("PASS: upstream and all Aqueous DMS units load together; old duplicate BusName reproduces the failure")
