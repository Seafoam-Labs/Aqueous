#!/usr/bin/env python3
"""Real socket/lifecycle tests using private headless Aqueous instances."""
import json
import os
from pathlib import Path
import select
import socket
import stat
import subprocess
import tempfile
import time

from ipc_test_client import Client

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('AQUEOUS_COMPOSITOR_BIN', ROOT / 'zig-out/bin/aqueous'))
FIXTURES = os.environ.get('AQUEOUS_IPC_FIXTURES_DIR')

def record(name, value):
    if not FIXTURES:
        return
    def sanitize(item):
        if isinstance(item, dict):
            return {key: ('6b94a179d09456846b94a179d0945684' if key == 'session' else sanitize(child)) for key, child in item.items()}
        if isinstance(item, list):
            return [sanitize(child) for child in item]
        return item
    target = Path(FIXTURES)
    target.mkdir(parents=True, exist_ok=True)
    (target / (name + '.json')).write_text(json.dumps(sanitize(value), indent=2, ensure_ascii=False) + '\n')


def wait(check, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(.02)
    raise AssertionError('condition timed out')


with tempfile.TemporaryDirectory(prefix='aq-ipc-') as tmp:
    base = Path(tmp)
    runtime = base / 'run'
    runtime.mkdir(mode=0o700)
    # Older outputd versions created this parent with mode 0755.
    (runtime / 'aqueous').mkdir(mode=0o755)
    config = base / 'config'
    config.mkdir()
    wm = config / 'wm.toml'
    wm.write_text('[workspace_transition]\nenabled = false\n'
                  '[[exec]]\nname = "ipc-env-test"\n'
                  'command = "printenv AQUEOUS_SOCKET > $XDG_RUNTIME_DIR/native-env"\n')
    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(config),
               HOME=str(base), WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2', WLR_RENDERER='pixman')
    for key in list(env):
        if key.startswith('AQUEOUS_') or key in ('WAYLAND_DISPLAY', 'DISPLAY', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
            env.pop(key)
    env.update(AQUEOUS_CONFIG=str(wm), AQUEOUS_SOCKET='/stale/inherited/socket')
    processes, clients, logs = [], [], []

    def start(label, extra=None, expect_socket=True):
        log = (base / (label + '.log')).open('w+')
        logs.append(log)
        child_env = env | (extra or {})
        script = 'printenv AQUEOUS_SOCKET > "$XDG_RUNTIME_DIR/' + label + '-env"'
        proc = subprocess.Popen([str(BIN), '-no-xwayland', '-c', script], env=child_env, stdout=log, stderr=log)
        processes.append(proc)

        def exported():
            if proc.poll() is not None:
                log.seek(0)
                raise AssertionError(log.read())
            path = runtime / (label + '-env')
            if not path.exists():
                return None
            return path.read_text().strip() if expect_socket else True
        value = wait(exported)
        return proc, Path(value) if expect_socket else None

    def connect(path):
        client = Client(path)
        clients.append(client)
        return client

    try:
        compositor, path = start('first')
        assert path.is_socket() and path.is_relative_to(runtime)
        assert stat.S_IMODE(path.stat().st_mode) == 0o600
        assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
        assert stat.S_IMODE((runtime / 'aqueous').stat().st_mode) == 0o700
        wait(lambda: (runtime / 'native-env').exists() and (runtime / 'native-env').read_text().strip() == str(path))
        control = connect(path)
        events = connect(path)
        assert control.session == events.session
        record('hello-request', dict(ipc=1, id='1', op='hello', params={}))
        record('hello-response', dict(ipc=1, id='1', ok=True, result=control.capabilities))
        initial = control.snapshot()
        record('snapshot-response', dict(ipc=1, id=str(control.counter), ok=True, result=dict(batch=initial)))
        workspace = next(e for e in initial['upsert'] if e['kind'] == 'workspace')
        record('subscribe-response', events.call('subscribe'))
        baseline = events.receive()
        record('snapshot-event', baseline)
        assert baseline['event'] == 'state' and baseline['batch']['type'] == 'snapshot'
        assert not select.select([events.socket], [], [], .15)[0]

        # No Wayland shell clients exist: socket subscribers alone drive publishing.
        for name in ('one', 'two', 'final 🐟 "quoted"'):
            response = control.command('workspace.rename', dict(id=workspace['id'], name=name))
            assert response['result']['status'] == 'applied'
        assert not events.buffer and not select.select([events.socket], [], [], .15)[0]
        record('ack-request', dict(ipc=1, id=str(events.counter + 1), session=events.session, op='ack', params=dict(delivery=baseline['delivery'])))
        record('ack-response', events.ack(baseline))
        delta = events.receive()
        record('delta-event', delta)
        record('command-response', response)
        assert delta['batch']['base_sequence'] == baseline['batch']['sequence']
        assert any(e['kind'] == 'workspace' and e['id'] == workspace['id'] and e['name'] == name for e in delta['batch']['upsert'])
        events.ack(delta)
        assert not events.buffer and not select.select([events.socket], [], [], .15)[0]
        stale = control.call('snapshot', ok=False, session='0' * 32)
        record('stale-session-error', stale)
        assert stale['error']['code'] == 'stale_session'
        assert control.command('workspace.rename', dict(id='4294967295', name='missing'), ok=False)['error']['code'] == 'not_found'
        assert control.command('window.move', dict(id='missing', output='1', workspace='2'), ok=False)['error']['code'] == 'invalid'
        assert control.command('spawn', {}, ok=False)['error']['code'] == 'unsupported'
        assert control.call('hello', ok=False)['error']['code'] == 'invalid'
        assert control.call('snapshot', ok=False, ipc=2)['error']['code'] == 'unsupported'

        # Fragment a UTF-8 codepoint and send only one request until its reply.
        frame = control.frame('command', dict(action='workspace.rename', fields=dict(id=workspace['id'], name='split 🐟')))
        record('command-request', frame)
        encoded = json.dumps(frame, ensure_ascii=False).encode() + b'\n'
        split = encoded.index('🐟'.encode()) + 2
        control.socket.sendall(encoded[:split])
        time.sleep(.03)
        control.socket.sendall(encoded[split:])
        assert control.receive()['result']['status'] == 'applied'

        # Pipelined requests receive a bounded busy response instead of replacing
        # the outstanding command's ID or executing a second mutation.
        first = control.frame('snapshot')
        second = control.frame('command', dict(action='workspace.rename', fields=dict(id=workspace['id'], name='must not execute')))
        control.socket.sendall(json.dumps(first).encode() + b'\n' + json.dumps(second).encode() + b'\n')
        responses = {r['id']: r for r in (control.receive(), control.receive())}
        assert responses[first['id']]['ok']
        assert responses[second['id']]['error']['code'] == 'busy'
        assert next(e for e in control.snapshot()['upsert'] if e['kind'] == 'workspace' and e['id'] == workspace['id'])['name'] == 'split 🐟'

        reconnect = connect(path)
        assert reconnect.snapshot()['base_sequence'] is None
        reconnect.close()
        time.sleep(.05)

        # Protocol failures close only the offending client.
        for payload in (b'{bad json}\n', b'\xff\n', b'x' * 65537,
                        b'[' * 17 + b'0' + b']' * 17 + b'\n'):
            bad = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            bad.settimeout(3)
            bad.connect(str(path))
            bad.sendall(payload)
            try:
                assert bad.recv(1) == b''
            except ConnectionResetError:
                pass
            bad.close()
            assert control.snapshot()['session'] == control.session
        invalid_ack = connect(path)
        invalid_ack.send(invalid_ack.frame('ack', dict(delivery='1')))
        try:
            invalid_ack.receive()
            raise AssertionError('invalid ack accepted')
        except (EOFError, ConnectionResetError):
            pass
        invalid_ack.close()
        repeated = connect(path)
        repeated.send(dict(ipc=1, id='1', op='hello', params={}))
        try:
            repeated.receive()
            raise AssertionError('reused ID accepted')
        except (EOFError, ConnectionResetError):
            pass
        repeated.close()

        # Large snapshot frames exercise streaming beyond one read buffer.
        for entry in control.snapshot()['upsert']:
            if entry['kind'] == 'workspace':
                control.command('workspace.rename', dict(id=entry['id'], name='q' * 1024))
        assert len(json.dumps(control.snapshot())) > 8192
        # A paused event reader does not prevent other connections progressing.
        for n in range(40):
            control.command('workspace.rename', dict(id=workspace['id'], name=str(n)))

        # Deliberately pipeline queries without reading replies until the kernel
        # send buffer fills. The server must resume partial writes and preserve
        # every frame/ID while unrelated command connections keep working.
        pressure = connect(path)
        requests = [pressure.frame('snapshot') for _ in range(5000)]
        pressure.socket.sendall(b''.join(json.dumps(r).encode() + b'\n' for r in requests))
        time.sleep(.1)
        assert control.snapshot()['session'] == control.session
        seen = set()
        successes = 0
        for _ in requests:
            reply = pressure.receive()
            assert reply['id'] not in seen
            seen.add(reply['id'])
            if reply['ok']:
                successes += 1
                assert reply['result']['batch']['type'] == 'snapshot'
            else:
                assert reply['error']['code'] == 'busy'
        assert seen == {r['id'] for r in requests} and successes > 0
        pressure.close()

        # A second compositor sharing the runtime cannot replace the first socket.
        second_proc, second_path = start('second')
        assert second_path != path
        other = connect(second_path)
        assert other.session != control.session
        assert control.snapshot()['session'] == control.session
        assert other.command('session.exit')['result']['status'] == 'accepted'
        assert second_proc.wait(timeout=5) == 0
        assert not second_path.exists() and not second_path.parent.exists() and path.is_socket()

        # Admission includes idle connections; excess peers cannot grow memory.
        time.sleep(.1)
        idle = []
        for _ in range(14):
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(2)
            sock.connect(str(path))
            idle.append(sock)
        time.sleep(.1)
        excess = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        excess.settimeout(2)
        excess.connect(str(path))
        assert excess.recv(1) == b''
        excess.close()
        for sock in idle:
            sock.close()
        accepted = control.command('session.exit')
        record('accepted-exit', accepted)
        assert accepted['result']['status'] == 'accepted'
        assert compositor.wait(timeout=5) == 0
        assert not path.exists() and not path.parent.exists()

        # Reject a symlink parent and clear the inherited endpoint on failure.
        parent = runtime / 'aqueous'
        parent.rmdir()
        target = base / 'symlink-target'
        target.mkdir(mode=0o700)
        parent.symlink_to(target, target_is_directory=True)
        unavailable, _ = start('unavailable', expect_socket=False)
        assert (runtime / 'unavailable-env').read_text() == ''
        assert unavailable.poll() is None
        assert not list(target.glob('*/ipc.sock'))
        unavailable.terminate()
        unavailable.wait(timeout=5)
        print('PASS: socket-only state/actions, framing, flow control, lifecycle, admission and environment')
    finally:
        for client in clients:
            client.close()
        for proc in reversed(processes):
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
        for log in logs:
            log.seek(0)
            text = log.read()
            if 'panic' in text or 'Segmentation fault' in text:
                print(text)
            log.close()
