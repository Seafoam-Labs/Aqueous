#!/usr/bin/env python3
"""Exercise installer orchestration without changing the host or compiling Zig."""
import hashlib
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "scripts/fedora-install.sh"


class FedoraInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="aqueous-fedora-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        (self.base / "fixture").mkdir()
        (self.base / "dependency").mkdir()
        (self.base / "dependency/LICENSE").write_text("fixture license\n")
        with tarfile.open(self.base / "dependency.tar.gz", "w:gz") as archive:
            archive.add(self.base / "dependency", arcname="dependency")
        checksum = hashlib.sha256((self.base / "dependency.tar.gz").read_bytes()).hexdigest()
        (self.base / "fixture/PKGBUILD").write_text(f"""
pkgver=0.7.0
source=('aqueous::git+https://github.com/Seafoam-Labs/Aqueous.git#tag=v0.7.0'
        'dependency.tar.gz::https://example.invalid/dependency.tar.gz')
sha256sums=('SKIP' '{checksum}')
prepare() {{
    test -f "$srcdir/dependency/LICENSE"
    echo prepare >> "$TEST_ROOT/phases"
    cd /
}}
build() {{
    test "$PWD" = "$srcdir"
    echo build >> "$TEST_ROOT/phases"
    if [[ ${{FAIL_BUILD:-0}} == 1 ]]; then return 23; fi
    cd /
}}
check() {{
    test "$PWD" = "$srcdir"
    echo check >> "$TEST_ROOT/phases"
    if [[ ${{FAIL_CHECK:-0}} == 1 ]]; then return 24; fi
    cd /
}}
package() {{
    test "$PWD" = "$srcdir"
    echo package >> "$TEST_ROOT/phases"
    mkdir -p "$pkgdir/etc/xdg/aqueous" "$pkgdir/usr/share/aqueous" \\
        "$pkgdir/usr/bin" "$pkgdir/usr/lib/aqueous" \\
        "$pkgdir/etc/xdg/quickshell/dms-plugins"
    printf 'spawn_terminal = "ghostty"\\n' > "$pkgdir/etc/xdg/aqueous/wm.toml"
    cp "$pkgdir/etc/xdg/aqueous/wm.toml" "$pkgdir/usr/share/aqueous/wm.toml"
    printf '#!/bin/sh\\nexit 0\\n' > "$pkgdir/usr/bin/aqueous"
    chmod 755 "$pkgdir/usr/bin/aqueous"
    touch "$pkgdir/usr/lib/aqueous/libwlroots-0.20.so"
    ln -s /usr/share/aqueous "$pkgdir/etc/xdg/quickshell/dms-plugins/aqueousPortal"
}}
""")

    def run_shell(self, body, **env):
        return subprocess.run(
            ["bash", "-c", 'source "$INSTALLER"\n' + body],
            env={**os.environ, "INSTALLER": str(INSTALLER),
                 "TEST_ROOT": str(self.base), **env},
            text=True, capture_output=True,
        )

    def run_installer(self, options="", **env):
        # Replace only host/network/compiler/package-manager boundaries.
        # Real archive verification, phase orchestration, file manifest and
        # spec generation run in the temporary build directory.
        return self.run_shell(r'''
fedora_host_check() { :; }
fedora_tools_check() { :; }
fedora_dependencies() { echo dependencies >> "$TEST_ROOT/events"; }
git() {
    if [[ $1 == clone ]]; then
        [[ "$*" == "clone --depth 1 --single-branch --branch master https://github.com/Seafoam-Labs/Aqueous.git "* ]]
        cp -a "$TEST_ROOT/fixture" "${@: -1}"
    elif [[ $1 == rev-parse ]]; then
        echo 123456789abc123456789abc123456789abc12345678
    elif [[ $1 == show ]]; then
        echo 1789030000
    else
        return 90
    fi
}
curl() { cp "$TEST_ROOT/dependency.tar.gz" "${@: -1}"; }
rpmbuild() {
    echo rpmbuild >> "$TEST_ROOT/events"
    local top=$fedora_work/rpmbuild
    mkdir -p "$top/RPMS/x86_64"
    touch "$top/RPMS/x86_64/aqueous-git-fixture.rpm"
}
rpm() { echo 'libc.so.6()(64bit)'; }
sudo() {
    [[ $1 == dnf && "$*" == *" install "* && ${@: -1} == *.rpm ]]
    echo install >> "$TEST_ROOT/events"
}
fedora_output="$TEST_ROOT/output with spaces"
''' + f"fedora_main {options}\n", **env)

    def work(self):
        return next((self.base / "output with spaces").glob("build.*"))

    def test_master_build_and_rpm_install(self):
        result = self.run_installer("--yes")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.base / "phases").read_text().splitlines(),
                         ["prepare", "build", "check", "package"])
        self.assertEqual((self.base / "events").read_text().splitlines(),
                         ["dependencies", "rpmbuild", "install"])
        work = self.work()
        self.assertIn("^git1789030000.", (work / "version").read_text())
        self.assertEqual((work / "payload/etc/xdg/aqueous/wm.toml").read_text(),
                         'spawn_terminal = "foot"\n')
        self.assertEqual((work / "payload/usr/share/doc/aqueous/master-commit").read_text(),
                         (work / "commit").read_text())
        files = (work / "rpmbuild/SOURCES/files.list").read_text().splitlines()
        self.assertIn('%config(noreplace) "/etc/xdg/aqueous/wm.toml"', files)
        self.assertIn('%dir "/usr/lib/aqueous"', files)
        self.assertIn('"/etc/xdg/quickshell/dms-plugins/aqueousPortal"', files)
        self.assertNotIn('%dir "/usr"', files)
        self.assertNotIn('%dir "/etc"', files)
        self.assertNotIn('%dir "/usr/bin"', files)

    def test_build_only_never_installs_rpm(self):
        result = self.run_installer("--build-only")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.base / "events").read_text().splitlines(),
                         ["dependencies", "rpmbuild"])

    def test_build_failure_prevents_packaging_and_install(self):
        result = self.run_installer(FAIL_BUILD="1")
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
        self.assertEqual((self.base / "phases").read_text().splitlines(), ["prepare", "build"])
        self.assertEqual((self.base / "events").read_text().splitlines(), ["dependencies"])

    def test_check_failure_prevents_packaging_and_install(self):
        result = self.run_installer(FAIL_CHECK="1")
        self.assertEqual(result.returncode, 24, result.stdout + result.stderr)
        self.assertEqual((self.base / "phases").read_text().splitlines(), ["prepare", "build", "check"])
        self.assertEqual((self.base / "events").read_text().splitlines(), ["dependencies"])

    def test_checksum_failure_stops_before_prepare(self):
        with (self.base / "dependency.tar.gz").open("ab") as archive:
            archive.write(b"corrupted")
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.base / "phases").exists())
        self.assertEqual((self.base / "events").read_text().splitlines(), ["dependencies"])

    def test_invalid_options_do_not_touch_host(self):
        for options in ("--unknown", "--skip-deps --dms-git"):
            result = self.run_installer(options)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.base / "events").exists())

    def test_help_works_without_fedora(self):
        result = subprocess.run(["bash", str(INSTALLER), "--help"], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("master", result.stdout)


if __name__ == "__main__":
    unittest.main()
