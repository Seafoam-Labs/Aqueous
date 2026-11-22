#!/usr/bin/env python3
"""Exercise drag cancellation over a non-accepting XWayland window.

The source must stay alive while its destroy signal tears down the drag, so
XWM can reset the DnD action on it before sending XdndLeave.
"""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

source, prefix = (Path(p).resolve() for p in sys.argv[1:])
env = dict(os.environ, PKG_CONFIG_PATH=str(prefix / 'lib/pkgconfig'), LD_LIBRARY_PATH=str(prefix / 'lib'))
flags = shlex.split(subprocess.check_output(
    ['pkg-config', '--cflags', '--libs', 'wlroots-0.20', 'wayland-server', 'pixman-1',
     'xcb', 'xcb-xfixes', 'xcb-render', 'xcb-errors'], env=env, text=True))
with tempfile.TemporaryDirectory(prefix='aqueous-dnd-xwayland-') as temporary:
    work = Path(temporary)
    (work / 'xwayland-dnd-source.h').write_text((source / 'xwayland/selection/dnd.c').read_text())
    (work / 'config.h').write_text('#define HAVE_XCB_ERRORS 1\n')
    subprocess.run(['cc', '-std=c11', '-D_POSIX_C_SOURCE=200809L', '-DWLR_USE_UNSTABLE',
                    '-DWLR_PRIVATE=', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                    '-I' + str(prefix / 'include/wlroots-0.20'), '-I' + str(source / 'include'), '-I' + str(work),
                    str(Path(__file__).parent / 'fixtures/dnd-xwayland-cancel.c'), *flags, '-lm', '-o', work / 'test'],
                   check=True, env=env)
    subprocess.run([work / 'test'], check=True, env=env, timeout=20)