#!/usr/bin/env python3
"""Exercise versioned text-input and DMA-BUF handlers with Wayland resources."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

source, prefix = (Path(p).resolve() for p in sys.argv[1:])
env = dict(os.environ, PKG_CONFIG_PATH=str(prefix / 'lib/pkgconfig'),
           LD_LIBRARY_PATH=str(prefix / 'lib'))
flags = shlex.split(subprocess.check_output(
    ['pkg-config', '--cflags', '--libs', 'wlroots-0.20', 'wayland-server', 'libdrm'],
    env=env, text=True))
protocols = Path(subprocess.check_output(
    ['pkg-config', '--variable=pkgdatadir', 'wayland-protocols'], text=True).strip())
with tempfile.TemporaryDirectory(prefix='aqueous-version-handlers-') as temporary:
    work = Path(temporary)
    for name, xml, implementation in [
        ('text-input-unstable-v3', 'unstable/text-input/text-input-unstable-v3.xml', 'wlr_text_input_v3'),
        ('linux-dmabuf-v1', 'stable/linux-dmabuf/linux-dmabuf-v1.xml', 'wlr_linux_dmabuf_v1'),
    ]:
        for mode, suffix in [('server-header', 'h'), ('private-code', 'c')]:
            subprocess.run(['wayland-scanner', mode, protocols / xml,
                            work / f'{name}-protocol.{suffix}'], check=True)
        (work / 'version-source.h').write_text((source / 'types' / f'{implementation}.c').read_text())
        extra = [str(source / 'util/shm.c')] if name == 'linux-dmabuf-v1' else []
        subprocess.run(['cc', '-std=c11', '-D_GNU_SOURCE', '-DWLR_USE_UNSTABLE', '-DWLR_PRIVATE=',
                        '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                        '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
                        '-I' + str(source / 'include'), '-I' + str(work),
                        str(Path(__file__).parent / 'fixtures' / f'{name}-versions.c'),
                        str(work / f'{name}-protocol.c'), *extra, *flags, '-o', str(work / 'test')],
                       check=True, env=env)
        subprocess.run([work / 'test'], check=True, env=env, timeout=20)
