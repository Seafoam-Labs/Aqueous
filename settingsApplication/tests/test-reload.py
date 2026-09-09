#!/usr/bin/env python3
"""Saving and compositor reload are separate outcomes; all commands are isolated."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DRIVER = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / 'zig-out/bin/aqueous-backend-test').resolve()
with tempfile.TemporaryDirectory(prefix='aqueous-settings-reload-') as tmp:
    base = Path(tmp)
    config = base / 'config/aqueous'
    config.mkdir(parents=True)
    for fixture in (ROOT / 'tests/fixtures').glob('*.toml'):
        (config / fixture.name).write_bytes(fixture.read_bytes())
    bindir = base / 'bin'
    bindir.mkdir()
    fake = bindir / 'aqueousctl'
    fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
if sys.argv[1:] == ['session', 'reload', '--json']:
    with open(os.environ['RELOAD_LOG'], 'a') as log:
        log.write(json.dumps(pathlib.Path(os.environ['AQUEOUS_CONFIG']).read_text()) + '\\n')
    mode = os.environ.get('RELOAD_MODE', 'applied')
    if mode == 'malformed':
        print('{}')
    else:
        print(json.dumps(dict(ok=mode != 'unsupported', status=mode)))
    sys.exit(1 if mode == 'unsupported' else 0)
print('[]')
''')
    fake.chmod(0o755)
    env = {k: v for k, v in os.environ.items() if not k.startswith('AQUEOUS_') and k not in ('WAYLAND_DISPLAY', 'DISPLAY', 'DBUS_SESSION_BUS_ADDRESS', 'LD_PRELOAD')}
    env.update(HOME=str(base), XDG_CONFIG_HOME=str(base / 'config'), XDG_STATE_HOME=str(base / 'state'),
               XDG_RUNTIME_DIR=str(base / 'runtime'), PATH=str(bindir) + ':' + env['PATH'],
               AQUEOUS_CONFIG=str(config / 'wm.toml'), RELOAD_LOG=str(base / 'reload.log'))
    def call(op, request=None, ok=True, reload='not_requested'):
        args = [str(DRIVER), op, '--shell', 'none', '--report-reload', 'true']
        if request is not None:
            args += ['--request', '-']
        result = subprocess.run(args, input=json.dumps(request) if request is not None else None,
                                env=env, capture_output=True, text=True, timeout=10)
        response = json.loads(result.stdout)
        assert (result.returncode == 0) == ok, (result, response)
        if ok:
            assert f'reload={reload}' in result.stderr, result.stderr
        return response

    snapshot = call('snapshot')
    old = (config / 'wm.toml').read_text()
    request = dict(protocol=1, expected_generation=snapshot['generation'], raw_files=dict(wm=old + '\n# applied-before-reload\n'))
    call('validate', request)
    call('apply', request | dict(expected_generation='stale'), ok=False)
    assert not (base / 'reload.log').exists()
    applied = call('apply', request, reload='applied')
    assert json.loads((base / 'reload.log').read_text()) == (config / 'wm.toml').read_text()
    # No-op Apply retries a failed reload, without resubmitting saved edits.
    for mode in ('unsupported', 'malformed', 'accepted', 'applied'):
        env['RELOAD_MODE'] = mode
        before = (config / 'wm.toml').read_bytes()
        result = call('apply', dict(protocol=1, expected_generation=applied['generation']),
                      reload='applied' if mode == 'applied' else 'failed')
        assert result['generation'] == applied['generation']
        assert (config / 'wm.toml').read_bytes() == before
    assert len((base / 'reload.log').read_text().splitlines()) == 5
    # A failed reload after a real save still returns the new generation.
    env['RELOAD_MODE'] = 'unsupported'
    updated = before.decode() + '\n# saved-with-reload-failure\n'
    result = call('apply', dict(protocol=1, expected_generation=applied['generation'], raw_files=dict(wm=updated)), reload='failed')
    assert result['generation'] != applied['generation']
    assert (config / 'wm.toml').read_text() == updated
print('Apply reload passed: save ordering, read-only operations, failed acknowledgement, retained saves, and retry.')
