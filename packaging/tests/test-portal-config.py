#!/usr/bin/env python3
"""Verify the built backend's real config lookup before it connects to D-Bus."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='aqueous-portal-config-', dir='/tmp') as directory:
    root = Path(directory)
    config = root / 'config/xdg-desktop-portal-aqueous'
    config.mkdir(parents=True)
    env = dict(os.environ, HOME=str(root), XDG_CONFIG_HOME=str(root / 'config'),
               XDG_CURRENT_DESKTOP='Aqueous', XDG_RUNTIME_DIR=str(root),
               DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'))
    def run():
        result = subprocess.run([binary, '-l', 'TRACE'], env=env, capture_output=True, text=True, timeout=5)
        # Failing to connect is deliberate: no live portal/session is touched.
        assert 'dbus: failed to connect' in result.stderr, result.stderr
        return result.stderr
    trace = run()
    assert '/etc/xdg/xdg-desktop-portal-aqueous/Aqueous' in trace, trace
    (config / 'config').write_text('[screencast]\nchooser_type=dmenu\nchooser_cmd=test-user-chooser\n')
    trace = run()
    assert 'chooser_cmd: test-user-chooser' in trace, trace
    assert '/etc/xdg/xdg-desktop-portal-aqueous/' not in trace, trace
    (config / 'Aqueous').write_text('[screencast]\nchooser_type=dmenu\nchooser_cmd=test-desktop-chooser\n')
    trace = run()
    assert 'chooser_cmd: test-desktop-chooser' in trace, trace
    assert (config / 'config').read_text().endswith('test-user-chooser\n')
print('Built portal config: /etc lookup and user/desktop override precedence passed')
