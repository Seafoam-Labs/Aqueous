#!/usr/bin/env python3
"""Fullscreen-only VRR policy with an explicit diagnostic virtual VRR backend."""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import uuid
from ipc_test_client import Client

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--ctl', type=Path, default=ROOT / 'zig-out/bin/aqueousctl')
    parser.add_argument('--renderer', choices=('pixman', 'vulkan'), default='pixman')
    parser.add_argument('--helper', type=Path, default=ROOT.parent / 'settingsApplication/zig-out/bin/aqueous-config')
    parser.add_argument('--xwayland', action='store_true')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-fullscreen-vrr-'))
    print(f'Artifacts: {work}', flush=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    children, logs = [], []

    def run(command):
        return subprocess.check_output([str(p) for p in command], env=env, text=True,
                                       stderr=subprocess.STDOUT, timeout=30)

    def launch(command, label):
        out, err = (work / f'{label}.jsonl').open('w'), (work / f'{label}.log').open('w')
        logs.extend((out, err))
        child = subprocess.Popen([str(p) for p in command], env=env, stdin=subprocess.PIPE,
                                 stdout=out, stderr=err, start_new_session=True)
        children.append(child)
        return child

    def wait(predicate, description):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            assert compositor.poll() is None, 'compositor exited'
            value = predicate()
            if value:
                return value
            time.sleep(.01)
        raise AssertionError(description)

    def events(label, kind=None):
        result = []
        for line in (work / f'{label}.jsonl').read_text().splitlines():
            try:
                value = json.loads(line)
                if kind is None or value['event'] == kind:
                    result.append(value)
            except ValueError:
                pass
        return result

    def command(child, label, value):
        before = len(events(label, 'command'))
        child.stdin.write(value.encode()); child.stdin.flush()
        wait(lambda: len(events(label, 'command')) > before, f'{label}: command {value}')

    def ctl(*values):
        return json.loads(run([args.ctl.resolve(), *values, '--json']))

    def window(label):
        return next((w for w in ctl('windows') if w.get('app_id') == label), None)

    def output_request(expected_ok=True, **data):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(3); client.connect(str(runtime / 'aqueous/outputd.sock'))
            client.sendall(json.dumps(data).encode() + b'\n')
            with client.makefile('r') as response:
                value = json.loads(response.readline())
        assert value.get('ok') == expected_ok, value
        return value

    try:
        protocols = Path('/usr/share/wayland-protocols')
        generated = []
        for name, relative in {
            'xdg-shell': 'stable/xdg-shell/xdg-shell.xml',
            'ext-foreign-toplevel-list': 'staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml',
            'ext-image-capture-source': 'staging/ext-image-capture-source/ext-image-capture-source-v1.xml',
            'ext-image-copy-capture': 'staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml',
        }.items():
            run(['wayland-scanner', 'client-header', protocols / relative, work / f'{name}-client-protocol.h'])
            code = work / f'{name}.c'
            run(['wayland-scanner', 'private-code', protocols / relative, code])
            generated.append(code)
        run(['cc', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/xdg-shell-states.c', *generated,
             '-lwayland-client', '-o', work / 'client'])
        shell_generated = [generated[0]]
        for name, xml in {
            'xdg-activation': protocols / 'staging/xdg-activation/xdg-activation-v1.xml',
            'shortcuts': protocols / 'unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml',
            'virtual-keyboard': ROOT / 'protocol/upstream/virtual-keyboard-unstable-v1.xml',
            'layer-shell': ROOT / 'protocol/upstream/wlr-layer-shell-unstable-v1.xml',
            'session-lock': protocols / 'staging/ext-session-lock/ext-session-lock-v1.xml',
            'aqueous-shell': ROOT / 'protocol/aqueous-shell-v1.xml',
            'ext-workspace': ROOT / 'protocol/upstream/ext-workspace-v1.xml',
            'pointer-constraints': protocols / 'unstable/pointer-constraints/pointer-constraints-unstable-v1.xml',
        }.items():
            run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'])
            code = work / f'{name}.c'
            run(['wayland-scanner', 'private-code', xml, code])
            shell_generated.append(code)
        run(['cc', '-Wall', '-Wextra', '-Werror', f'-I{work}', ROOT / 'scripts/fixtures/shell-client.c',
             *shell_generated, '-lwayland-client', '-lxkbcommon', '-o', work / 'shell-client'])
        if args.xwayland:
            run(['cc', '-Wall', '-Wextra', '-Werror', ROOT / 'scripts/fixtures/unmanaged-x11.c',
                 '-lX11', '-o', work / 'xclient'])
        runtime = work / 'runtime'; runtime.mkdir(mode=0o700)
        for name in ('home', 'config', 'cache', 'state'):
            (work / name).mkdir()
        env.update(HOME=str(work / 'home'), XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'),
                   XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'),
                   WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2', WLR_RENDERER=args.renderer)
        for name in ('CONFIG', 'RULES', 'OUTPUTS', 'INPUT', 'LAYOUT'):
            path = work / f'{name.lower()}.toml'; path.write_text('')
            env[f'AQUEOUS_{name}'] = str(path)
        (work / 'config.toml').write_text('[layout]\ndefault = "floating"\n[blur]\nenabled = false\n[workspace_transition]\nenabled = false\n[input]\nfocus_follows_mouse = false\n')
        (work / 'rules.toml').write_text(''.join(
            f'[[window]]\napp_id = "{label}"\nfloating = true\nwidth = 400\nheight = 300\n'
            for label in ('vrr-left','vrr-right')))
        compositor = launch([args.compositor.resolve(), *([] if args.xwayland else ['-no-xwayland']),
                             '-log-level', 'debug', '-c', 'printenv AQUEOUS_SOCKET DISPLAY > "$XDG_RUNTIME_DIR/connection"'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None), 'no display')
        wait(lambda: (runtime / 'aqueous/outputd.sock').exists(), 'no output service')
        connection = wait(lambda: (runtime/'connection').read_text().splitlines() if (runtime/'connection').exists() else None, 'no IPC connection')
        env['AQUEOUS_SOCKET'] = connection[0]
        if args.xwayland:
            assert len(connection) == 2, '--xwayland requires a compositor built with -Dxwayland=true'
            env['DISPLAY'] = connection[1]
        def outputs():
            return {o['name']:o for o in output_request(op='list')['outputs']}

        def set_output(name, **values):
            return output_request(op='set', changes=[dict(name=name, **values)])

        def probe(name, action='status', **values):
            return output_request(op='test_output_retry', name=name, action=action, **values)

        def expect(name, target, actual=None):
            return wait(lambda: o if (o := outputs()[name])['effective_adaptive_sync'] == target and
                        (actual is None or o['actual_vrr'] == actual) else None,
                        f'{name}: target={target}, actual={actual}; {outputs()}')

        def winstate(label, key, value):
            ctl('window', 'state', '--id', window(label)['id'], '--'+key, str(value).lower())

        def activate(label):
            ctl('window', 'activate', '--id', window(label)['id'], '--seat', 'default')

        def records(kind):
            return [r for r in ctl('shell','snapshot')['upsert'] if r['kind']==kind]

        names = sorted(outputs())
        left,right = names
        for name in names:
            set_output(name, adaptive_sync=True, fullscreen_only_adaptive_sync=True)
            expect(name,False,False)
            probe(name, 'vrr_backend', enabled=True)
        clients={}
        for label,name in [('vrr-left',left),('vrr-right',right)]:
            clients[label]=launch([work/'client',7,label],label)
            wait(lambda: window(label), 'window not mapped')
            ctl('window','move','--id',window(label)['id'],'--output',name)
            wait(lambda: window(label)['output']==name, 'output move')
        activate('vrr-left')
        command(clients['vrr-left'],'vrr-left','x')
        expect(left,False,False)  # Maximization is not fullscreen.
        command(clients['vrr-left'],'vrr-left','X')
        command(clients['vrr-left'],'vrr-left','f')
        expect(left,True,True); expect(right,False,False)
        activate('vrr-right'); expect(left,True,True)
        command(clients['vrr-right'],'vrr-right','f')
        expect(right,True,True)
        command(clients['vrr-right'],'vrr-right','F')
        expect(right,False,False)
        attempt=probe(left)['vrr_attempts']
        for _ in range(3):
            activate('vrr-left'); activate('vrr-right')
        assert probe(left)['vrr_attempts']==attempt,'stable fullscreen retried VRR'
        print('PASS master/modifier policy, native fullscreen, maximization, independent outputs and focus',flush=True)

        # Fullscreen on an inactive workspace must not qualify.
        out=next(o for o in records('output') if o['name']==left)
        old_workspace=out['active_workspace']
        other=next(w for w in records('workspace') if w['output']==out['id'] and w['id']!=old_workspace)
        ctl('workspace','activate','--id',other['id']); expect(left,False,False)
        ctl('workspace','activate','--id',old_workspace); expect(left,True,True)
        ctl('window','move','--id',window('vrr-left')['id'],'--output',right)
        expect(left,False,False)
        expect(right,True,True)
        ctl('window','move','--id',window('vrr-left')['id'],'--output',left)
        expect(left,True,True); expect(right,False,False)
        winstate('vrr-left','minimized',True); expect(left,False,False)
        activate('vrr-left'); winstate('vrr-left','fullscreen',True); expect(left,True,True)
        ctl('overview','show','--output',left); expect(left,False,False)
        ctl('overview','hide'); expect(left,True,True)
        locker=launch([work/'shell-client','lock'],'locker')
        wait(lambda:'locked' in (work/'locker.jsonl').read_text(),'session lock')
        expect(left,False,False)
        locker.stdin.write(b'unlock\n');locker.stdin.flush();assert locker.wait(timeout=5)==0
        expect(left,True,True)
        probe(left,'vrr_inactive',inactive=True);expect(left,False,False)
        probe(left,'vrr_inactive',inactive=False);expect(left,True,True)
        set_output(left,enabled=False); expect(left,False)
        set_output(left,enabled=True); winstate('vrr-left','fullscreen',True)
        # Reestablish location after output disable migrated its windows.
        ctl('window','move','--id',window('vrr-left')['id'],'--output',left)
        winstate('vrr-left','fullscreen',True);expect(left,True,True)
        print('PASS workspace, output migration/power, minimize, overview, lock and session transitions',flush=True)

        set_output(left,adaptive_sync=False);expect(left,False,False)
        set_output(left,adaptive_sync=True);expect(left,True,True)
        command(clients['vrr-left'],'vrr-left','F');expect(left,False,False)
        set_output(left,fullscreen_only_adaptive_sync=False);expect(left,True,True)
        set_output(left,fullscreen_only_adaptive_sync=True);expect(left,False,False)
        probe(left,'vrr_fail')
        command(clients['vrr-left'],'vrr-left','f');expect(left,True,False)
        wait(lambda:outputs()[left]['adaptive_sync_error']=='commit_failed','failure not exposed')
        attempts=probe(left)['vrr_attempts']
        for _ in range(3):activate('vrr-right');activate('vrr-left')
        assert probe(left)['vrr_attempts']==attempts,'failed enable retried'
        assert outputs()[left]['adaptive_sync'] and outputs()[left]['fullscreen_only_adaptive_sync']
        command(clients['vrr-left'],'vrr-left','F');expect(left,False,False)
        command(clients['vrr-left'],'vrr-left','f');expect(left,True,True)
        probe(left,'vrr_fail')
        command(clients['vrr-left'],'vrr-left','F');expect(left,False,True)
        wait(lambda:outputs()[left]['adaptive_sync_error']=='commit_failed','disable failure not exposed')
        attempts=probe(left)['vrr_attempts']
        activate('vrr-right');activate('vrr-left')
        assert probe(left)['vrr_attempts']==attempts,'failed disable retried'
        set_output(left,fullscreen_only_adaptive_sync=True);expect(left,False,False)
        probe(left,'vrr_backend',enabled=False)
        command(clients['vrr-left'],'vrr-left','f');expect(left,True,False)
        wait(lambda:outputs()[left]['adaptive_sync_error']=='unsupported','unsupported VRR not reported')
        probe(left,'vrr_backend',enabled=True);expect(left,True,True)
        print('PASS master off, unconditional mode, enable/disable rejection, retry suppression and recovery',flush=True)

        # The modifier survives profile serialization and partial runtime edits.
        output_request(op='save_profile',name='vrr-profile',outputs=[dict(name=left,adaptive_sync=True,fullscreen_only_adaptive_sync=True)])
        assert 'fullscreen_only_adaptive_sync = true' in (work/'outputs.toml').read_text()
        set_output(left,fullscreen_only_adaptive_sync=False)
        output_request(op='apply_profile',name='vrr-profile')
        wait(lambda:outputs()[left]['fullscreen_only_adaptive_sync'],'profile lost modifier')
        set_output(left,scale=1.0)
        assert outputs()[left]['fullscreen_only_adaptive_sync']
        # Unsupported modifier values must not silently become omission.
        with socket.socket(socket.AF_UNIX) as sock:
            sock.connect(str(runtime/'aqueous/outputd.sock'))
            sock.sendall(json.dumps(dict(op='set',changes=[dict(name=left,fullscreen_only_adaptive_sync='true')])).encode()+b'\n')
            with sock.makefile('r') as response: assert not json.loads(response.readline())['ok']

        # Preview hardware expectations follow fullscreen without changing the
        # candidate digest or extending the confirmation deadline.
        # Adopt the profile file written through the compatibility service into
        # the canonical generation before opening a protected helper transaction.
        ctl('session','reload')
        def helper(op, request=None, *flags):
            response = subprocess.run([str(args.helper.resolve()), op, '--shell', 'none', *flags,
                                       *(['--request', '-'] if request is not None else [])],
                                      input=json.dumps(request) if request is not None else None,
                                      text=True, capture_output=True, env=env, timeout=35)
            value = json.loads(response.stdout)
            assert value['ok'], (value, response.stderr)
            return value

        ipc = Client(env['AQUEOUS_SOCKET'])
        def preview(master=True):
            snap = helper('snapshot')
            text = ''.join(f'[[output]]\nname = "{name}"\nadaptive_sync = {str(master).lower()}\nfullscreen_only_adaptive_sync = true\n' for name in names)
            request = dict(protocol=1, expected_generation=snap['generation'], raw_files={'outputs': text})
            checked = helper('validate', request)
            assert checked['candidate_impact']['complete'], checked['candidate_impact']
            model = wait(lambda: m if (m := ipc.call('display.snapshot')['result'])['observation']=='current' else None, 'display idle')
            params = dict(display_revision=model['display_revision'], candidate_digest=checked['candidate_review']['candidate_digest'],
                          expected_generation=snap['generation'], wm_source=snap['raw_files']['wm'], outputs_source=text)
            lease = ipc.call('display.preview.begin', params)['result']
            wait(lambda: status(lease['token'])['state']=='previewing', 'preview presentation')
            return lease['token'], request, params

        def status(token):
            return ipc.call('display.preview.status', dict(token=token))['result']

        command(clients['vrr-left'],'vrr-left','F');expect(left,False,False)
        set_output(left,adaptive_sync=False)
        token, request, params = preview()
        remaining = status(token)['remaining_ms']
        command(clients['vrr-left'],'vrr-left','f');expect(left,True,True)
        wait(lambda: status(token)['state']=='previewing','fullscreen preview revalidation')
        command(clients['vrr-left'],'vrr-left','F');expect(left,False,False)
        wait(lambda: status(token)['state']=='previewing','desktop preview revalidation')
        assert status(token)['remaining_ms'] <= remaining
        ipc.call('display.preview.revert',dict(token=token))
        wait(lambda:status(token)['state']=='reverted','preview revert')
        assert not outputs()[left]['adaptive_sync']
        token, request, params = preview()
        command(clients['vrr-left'],'vrr-left','f');expect(left,True,True)
        wait(lambda: status(token)['state']=='previewing','Keep after fullscreen transition')
        request.update(preview_token=token,candidate_digest=params['candidate_digest'])
        result=helper('apply',request,'--result','v1','--operation-id',str(int(time.time()))+'-'+uuid.uuid4().hex)
        assert result['display']=='kept' and result['save']=='saved',result
        assert status(token)['state']=='kept'
        assert 'fullscreen_only_adaptive_sync = true' in (work/'outputs.toml').read_text()
        token, _, _ = preview(master=False)
        expect(left,False,False)
        command(clients['vrr-left'],'vrr-left','F');expect(left,False,False)
        ipc.call('display.preview.revert',dict(token=token))
        wait(lambda:status(token)['state']=='reverted','conditional baseline reevaluation')
        expect(left,False,False)
        assert outputs()[left]['adaptive_sync'] and outputs()[left]['fullscreen_only_adaptive_sync']
        # A failed automatic toggle invalidates a preview and restores baseline.
        set_output(left,adaptive_sync=False)
        token, _, _ = preview()
        probe(left,'vrr_fail')
        command(clients['vrr-left'],'vrr-left','f')
        wait(lambda:status(token)['state']=='invalidated','failed preview rollback')
        expect(left,False,False)
        assert not outputs()[left]['adaptive_sync']
        ipc.close()
        set_output(left,adaptive_sync=True)
        print('PASS preview target changes, fixed confirmation deadline, Keep and failed-toggle rollback',flush=True)

        if args.xwayland:
            xclient=launch([work/'xclient'],'xclient')
            def xwindow():
                return next((w for w in records('window') if w.get('class')=='aq-notification-test'),None)
            xwin=wait(xwindow,'Xwayland window')
            ctl('window','move','--id',xwin['id'],'--output',right)
            def xcommand(value):
                count=(work/'xclient.jsonl').read_text().count('ok')
                xclient.stdin.write((value+'\n').encode());xclient.stdin.flush()
                wait(lambda:(work/'xclient.jsonl').read_text().count('ok')>count,'X11 request')
            xcommand('fullscreen');expect(right,True,True)
            activate('vrr-left');expect(right,True,True)
            xcommand('unmap');expect(right,True,True)
            xcommand('map');expect(right,True,True)
            xcommand('type _NET_WM_WINDOW_TYPE_DIALOG');xcommand('managed');expect(right,True,True)
            xcommand('unmanaged');expect(right,True,True)
            xcommand('unfullscreen');expect(right,False,False)
            xcommand('fullscreen');expect(right,True,True)
            ctl('window','move','--id',xwin['id'],'--output',left)
            expect(right,False,False);expect(left,True,True)
            xclient.stdin.write(b'quit\n');xclient.stdin.flush();assert xclient.wait(timeout=5)==0
            print('PASS Xwayland fullscreen requests, notifications, focus and migration',flush=True)

        for label,child in clients.items():
            child.stdin.write(b'q');child.stdin.flush();assert child.wait(timeout=5)==0
        wait(lambda:not window('vrr-left'),'window destruction')
        expect(left,False,False);expect(right,False,False)
        output_request(expected_ok=False,op='set',changes=[dict(name=right,mirror_of=left)])
        assert not outputs()[right]['mirror_of'],'conditional mode bypassed mirror rejection'
        set_output(right,adaptive_sync=False,mirror_of=left)
        expect(right,False,False)
        set_output(left,fullscreen_only_adaptive_sync=False);expect(left,True,True);expect(right,False,False)
        set_output(right,mirror_of='')
        set_output(left,fullscreen_only_adaptive_sync=True);expect(left,False,False)
        # CLI metadata reports policy and actual state without changing legacy adaptive_sync.
        cli=ctl('outputs');assert all('fullscreen_only_adaptive_sync' in o and 'actual_vrr' in o for o in cli)
        print('PASS profile/partial-edit persistence, invalid values, destruction and CLI observations',flush=True)
        print('PASS mirror destination rejection and independent source policy',flush=True)
        # Output destruction exits fullscreen under existing policy. Reevaluate
        # the surviving output and permit a fresh fullscreen request there.
        replacement=launch([work/'client',7,'vrr-hotplug'],'vrr-hotplug')
        wait(lambda:window('vrr-hotplug'),'hotplug client')
        ctl('window','move','--id',window('vrr-hotplug')['id'],'--output',right)
        set_output(right,adaptive_sync=True)
        activate('vrr-hotplug');command(replacement,'vrr-hotplug','f');expect(right,True,True)
        probe(right,'destroy')
        wait(lambda:right not in outputs(),'output removal')
        activate('vrr-hotplug');expect(left,False,False)
        command(replacement,'vrr-hotplug','f');expect(left,True,True)
        replacement.stdin.write(b'q');replacement.stdin.flush();assert replacement.wait(timeout=5)==0
        expect(left,False,False)
        print('PASS fullscreen exit and re-entry on the surviving output after hot-unplug',flush=True)
    finally:
        for child in reversed(children):
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL); child.wait()
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
