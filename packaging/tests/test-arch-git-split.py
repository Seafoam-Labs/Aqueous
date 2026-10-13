#!/usr/bin/env python3
"""Verify the single Arch package base and its complete build/install cohort."""
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
RECIPE = ROOT / 'packaging/arch/aqueous-git/PKGBUILD'
metadata = subprocess.check_output(['makepkg', '--printsrcinfo'], cwd=RECIPE.parent, text=True)
assert metadata == RECIPE.with_name('.SRCINFO').read_text(), 'Stale .SRCINFO'
base = {}
packages = {}
section = base
for line in metadata.splitlines():
    if ' = ' not in line:
        continue
    key, value = line.strip().split(' = ', 1)
    if key == 'pkgname':
        section = packages.setdefault(value, {})
    else:
        section.setdefault(key, []).append(value)
assert base['pkgbase'] == ['aqueous-git']
assert len(packages) == 11 and 'aqueous-core-git' in packages and 'aqueous-git' in packages
assert 'depends' not in base, 'Internal dependencies must not be external build inputs'
version = base['pkgver'][0] + '-' + base['pkgrel'][0]
optional = {f'aqueous-shell-{shell}-git' for shell in ('dms', 'noctalia', 'pearl')}
selected = packages.keys() - optional
assert len(selected) == 8
for name, info in packages.items():
    for dependency in info.get('depends', []):
        target = re.split(r'[<>=]', dependency)[0]
        assert 'welcome' not in target and target not in ('gtk4', 'shelly', 'sudo')
        if target in packages:
            assert dependency == f'{target}={version}', (name, dependency)
            if name in selected:
                assert target in selected, (name, dependency)
        if name in selected:
            assert target not in ('pearl-git', 'dms-shell', 'noctalia'), (name, dependency)
meta = packages['aqueous-git']
assert meta['replaces'] == ['aqueous-desktop-git']
assert meta['conflicts'] == ['aqueous-desktop-git']
assert meta['provides'] == [f'aqueous-desktop-git={version}']
assert packages['aqueous-session-git']['conflicts'] == ['aqueous-welcome-git']
for name in ('aqueous-core-git', 'aqueous-desktop-git'):
    assert not (ROOT / 'packaging/arch' / name / 'PKGBUILD').exists()

# Check that the two native build pipelines run once, share a revision, and
# stop on failure. Package functions must route each payload to its own root.
with tempfile.TemporaryDirectory(prefix='aqueous-split-') as directory:
    stage = Path(directory)
    helpers = stage / 'aqueous/packaging/git'
    helpers.mkdir(parents=True)
    log = stage / 'calls'
    for name in ('build.sh', 'desktop-build.sh'):
        (helpers / name).write_text('''#!/usr/bin/env bash
set -eu
printf '%s|%s|%s|%s|%s|%s\\n' "${0##*/}" "$1" "$2" "${3:-core}" "$pkgver" "${pkgdir:-}" >> "$CALL_LOG"
if [[ ${FAIL_HELPER:-} == "${0##*/}" && ${FAIL_ACTION:-} == "$1" ]]; then exit 23; fi
''')
    env = dict(os.environ, srcdir=str(stage), CALL_LOG=str(log))
    script = '''set -euo pipefail
source "$1"
build
check
for name in "${pkgname[@]}"; do
    (pkgdir="$srcdir/$name"; "package_$name")
done
'''
    subprocess.run(['bash', '-c', script, '_', str(RECIPE)], env=env, check=True)
    calls = [line.split('|') for line in log.read_text().splitlines()]
    assert [(c[0], c[1]) for c in calls[:4]] == [
        ('build.sh', 'build'), ('desktop-build.sh', 'build'),
        ('build.sh', 'check'), ('desktop-build.sh', 'check')]
    assert all(c[2] == 'git' and c[4] == base['pkgver'][0] for c in calls)
    expected = {'core': 'aqueous-core-git', 'session': 'aqueous-session-git',
                'portal': 'xdg-desktop-portal-aqueous-git',
                **{f'integration-{shell}': f'aqueous-integration-{shell}-git'
                   for shell in ('dms', 'noctalia', 'pearl')}}
    assert len(calls[4:]) == len(expected)
    for helper, action, channel, component, revision, destination in calls[4:]:
        assert action == 'package' and destination == str(stage / expected.pop(component))
        assert helper == ('build.sh' if component == 'core' else 'desktop-build.sh')
    assert not expected
    for action in ('build', 'check'):
        log.unlink()
        result = subprocess.run(['bash', '-c', 'set -e; source "$1"; "$2"', '_', str(RECIPE), action],
                                env=dict(env, FAIL_HELPER='build.sh', FAIL_ACTION=action))
        assert result.returncode == 23
        assert len(log.read_text().splitlines()) == 1, 'Continued after core failure'

# Existing stable ownership conflicts must apply only to the old combined Git
# package, not to the new meta package at the transition version or later.
assert int(subprocess.check_output(['vercmp', version, '1.0.2.r6'], text=True)) >= 0
for path in (ROOT / '.SRCINFO', ROOT / 'packaging/arch/aqueous/.SRCINFO',
             ROOT / 'packaging/arch/aqueous-desktop/.SRCINFO',
             ROOT / 'packaging/devario/aqueous-devario/.SRCINFO'):
    text = path.read_text()
    assert '\tconflicts = aqueous-git\n' not in text, path
    assert '\tconflicts = aqueous-git<1.0.2.r6\n' in text, path
print('PASS: one Arch split base, exact internal dependencies, optional shells, migration metadata, build/check dispatch and failure propagation')
