#!/usr/bin/env python3
"""Exercise the pinned wlroots pointer handlers with real Wayland resources."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

source, prefix = (Path(p).resolve() for p in sys.argv[1:])
env = dict(os.environ, PKG_CONFIG_PATH=str(prefix / 'lib/pkgconfig'), LD_LIBRARY_PATH=str(prefix / 'lib'))
flags = shlex.split(subprocess.check_output(
    ['pkg-config', '--cflags', '--libs', 'wlroots-0.20', 'wayland-server', 'pixman-1'], env=env, text=True))
with tempfile.TemporaryDirectory(prefix='aqueous-pointer-enter-') as temporary:
    work = Path(temporary)
    (work / 'pointer-source.h').write_text((source / 'types/seat/wlr_seat_pointer.c').read_text())
    subprocess.run(['cc', '-std=c11', '-D_POSIX_C_SOURCE=200809L', '-DWLR_USE_UNSTABLE',
                    '-DWLR_PRIVATE=', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-I' + str(source / 'include'), '-I' + str(work),
                    str(Path(__file__).parent / 'fixtures/pointer-enter.c'), *flags, '-lm', '-o', work / 'test'], check=True, env=env)
    subprocess.run([work / 'test'], check=True, env=env, timeout=20)
