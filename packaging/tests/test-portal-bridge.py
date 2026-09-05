#!/usr/bin/env python3
"""Exercise the real bridge with a separate fake DMS CLI/socket client."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

bridge = str(Path(sys.argv[1]).resolve())
fake = r'''#!/usr/bin/python3
import json, os, pathlib, socket, subprocess, sys, time
root = pathlib.Path(os.environ['XDG_RUNTIME_DIR'])
settings = pathlib.Path(os.environ['XDG_CONFIG_HOME']) / 'DankMaterialShell/plugin_settings.json'
args = sys.argv[1:]
if args == ['ipc', 'call', 'plugins', 'status', 'aqueousPortal']:
    counter = root / 'status-count'
    count = int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(count + 1))
    data = json.loads(settings.read_text()) if settings.exists() else {}
    if count < int(os.environ.get('FAKE_DISCOVERY_DELAY', '0')):
        print('PLUGIN_NOT_FOUND: aqueousPortal')
    else:
        print('loaded' if data.get('aqueousPortal', {}).get('enabled') else 'disabled')
elif args == ['ipc', 'call', 'plugins', 'enable', 'aqueousPortal']:
    settings.parent.mkdir(parents=True, exist_ok=True)
    data = json.loads(settings.read_text()) if settings.exists() else {}
    data['aqueousPortal'] = {'enabled': True}
    settings.write_text(json.dumps(data))
    print('PLUGIN_ENABLE_SUCCESS: aqueousPortal')
elif args[:4] == ['ipc', 'call', 'aqueousPortal', 'open']:
    token = args[4]
    assert len(token) == 32 and all(c in '0123456789abcdef' for c in token)
    subprocess.Popen([sys.executable, __file__, 'worker', token],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    print('opened')
elif args[0] == 'worker':
    with socket.socket(socket.AF_UNIX) as sock:
        sock.connect(str(root / 'aqueous-portal' / (args[1] + '.sock')))
        with sock.makefile('rb') as stream:
            request = json.loads(stream.readline())
            assert request['version'] == 1
            (root / 'received.json').write_text(json.dumps(request))
            mode = os.environ.get('FAKE_MODE', 'select')
            if mode == 'disconnect':
                sys.exit(0)
            if mode == 'hold':
                sock.settimeout(10)
                sock.recv(1)
                sys.exit(0)
            response = {'index': int(os.environ.get('FAKE_INDEX', '1'))}
            if mode == 'cancel': response['index'] = None
            payload = b'bad json' if mode == 'invalid' else json.dumps(response).encode()
            sock.sendall(payload + b'\n')
            sock.settimeout(5)
            sock.recv(1)
else:
    raise RuntimeError(args)
'''

with tempfile.TemporaryDirectory(prefix='aq-portal-', dir='/tmp') as directory:
    root = Path(directory)
    (root / 'bin').mkdir()
    runtime = root / 'run'
    runtime.mkdir(mode=0o700)
    (root / 'bin/dms').write_text(fake)
    (root / 'bin/dms').chmod(0o755)
    env = dict(os.environ, PATH=str(root / 'bin'), XDG_RUNTIME_DIR=str(runtime),
               XDG_CONFIG_HOME=str(root / 'config'), FAKE_DISCOVERY_DELAY='2')
    settings = root / 'config/DankMaterialShell/plugin_settings.json'
    labels = 'Monitor: DP-1 Vendor display\nWindow: Résumé $(touch sentinel) "quoted" (id-2)\nWindow: Résumé (id-3)\n'

    def run(data=labels, mode='select', index=1):
        return subprocess.run([bridge], input=data.encode(), capture_output=True,
                              env=dict(env, FAKE_MODE=mode, FAKE_INDEX=str(index)), timeout=15)

    def clean():
        assert not list((runtime / 'aqueous-portal').glob('*.sock'))

    settings.parent.mkdir(parents=True)
    settings.write_text('{"unrelated":{"enabled":true}}')
    result = run()
    assert result.returncode == 0, result.stderr
    assert result.stdout.decode() == labels.splitlines()[1] + '\n'
    assert json.loads(settings.read_text()) == {'aqueousPortal': {'enabled': True}, 'unrelated': {'enabled': True}}
    assert json.loads((runtime / 'received.json').read_text())['choices'] == labels.splitlines()
    clean()
    for mode, expected in [('cancel', 0), ('invalid', 1), ('disconnect', 1)]:
        result = run(mode=mode)
        assert result.returncode == expected and result.stdout == b'', (mode, result)
        clean()
    for index in [-1, 3]:
        result = run(index=index)
        assert result.returncode == 1 and b'InvalidResponse' in result.stderr and not result.stdout
        clean()
    for data in ['', 'x' * (1024 * 1024 + 1), 'bad\x00label\n']:
        result = run(data=data)
        assert result.returncode == 1 and not result.stdout
    # The bridge drains large input and the socket without pipe-buffer deadlocks.
    many = '\n'.join(f'Window: {i} ' + 'x' * 200 for i in range(1000)) + '\n'
    result = run(data=many, index=999)
    assert result.returncode == 0 and result.stdout.decode() == many.splitlines()[999] + '\n', result
    original = json.dumps({'aqueousPortal': {'enabled': False}, 'unrelated': {'enabled': True}})
    settings.write_text(original)
    result = run()
    assert b'PluginDisabled' in result.stderr and not result.stdout
    assert settings.read_text() == original
    settings.write_text('{invalid')
    result = run()
    assert b'PluginSettingsInvalid' in result.stderr and settings.read_text() == '{invalid'
    settings.write_text('{"aqueousPortal":{"enabled":true}}')
    first = subprocess.Popen([bridge], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, env=dict(env, FAKE_MODE='hold'))
    try:
        first.stdin.write(labels.encode())
        first.stdin.close()
        first.stdin = None
        until = time.monotonic() + 5
        while not list((runtime / 'aqueous-portal').glob('*.sock')):
            assert first.poll() is None
            assert time.monotonic() < until
            time.sleep(0.02)
        result = run()
        assert b'ChooserBusy' in result.stderr and not result.stdout
        first.terminate()
        out, err = first.communicate(timeout=3)
        assert first.returncode == 1 and not out and b'RequestClosed' in err, (out, err)
    finally:
        if first.poll() is None:
            first.kill()
            first.wait()
    clean()
    # Request cleanup releases the lock for the next caller.
    assert run(index=0).returncode == 0
    clean()
print('Portal bridge: exact selection, cancellation, errors, limits, disablement, concurrency and cleanup passed')
