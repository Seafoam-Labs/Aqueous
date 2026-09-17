#!/usr/bin/env python3
"""Check component/Gentoo package staging and settings GUI retirement without installation."""
import pathlib,subprocess,tomllib
ROOT=pathlib.Path(__file__).resolve().parents[2]
helper_root = ROOT / 'settingsApplication'
for retired_source in ['src/main.zig', 'src/app.zig', 'src/ui_tests.zig', 'src/services/shortcut_capture.c', 'packaging/org.aqueous.Settings.desktop', 'quark/prepare.py']:
    assert not (helper_root / retired_source).exists(), retired_source
assert '.dependencies = .{}' in (helper_root / 'build.zig.zon').read_text()
assert 'aqueous-settings' not in (helper_root / 'build.zig').read_text()
config=tomllib.loads((ROOT/'packaging/noctalia/config.toml').read_text())
assert 'aqueous_settings' not in config['bar']['default']['start']
assert 'aqueous/settings' not in config.get('plugins',{}).get('enabled',[])
for path in ['packaging/noctalia.service','nix/module.nix']:
    assert 'enable-noctalia-plugin' not in (ROOT/path).read_text()
assert not (ROOT/'plugin').exists() and not (ROOT/'dms-plugin').exists()
# Exercise the maintained component recipes and Gentoo staging rather than
# removed combined PKGBUILDs or the obsolete binary package() entry point.
subprocess.run(['python3', str(ROOT/'packaging/tests/test-dms-git-packaging.py')], check=True)
subprocess.run(['bash', str(ROOT/'packaging/tests/test-components.sh')], check=True)
print('retired settings GUI and plugins absent; component staging passed')
