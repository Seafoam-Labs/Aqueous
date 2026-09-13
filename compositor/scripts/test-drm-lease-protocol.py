#!/usr/bin/env python3
"""Test the actual pinned wlroots lease handlers with synthetic DRM calls.

Arguments are a wlroots source tree and installed dependency prefix. No GPU is
required; this exercises Wayland resources and event logging, not kernel KMS.
"""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

sanitize = '--sanitize' in sys.argv
source, prefix = (Path(p).resolve() for p in sys.argv[1:] if p != '--sanitize')
sanitize_flags = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-g'] if sanitize else []
env = dict(os.environ, PKG_CONFIG_PATH=str(prefix / 'lib/pkgconfig'),
           LD_LIBRARY_PATH=str(prefix / 'lib'))
flags = shlex.split(subprocess.check_output(
    ['pkg-config', '--cflags', '--libs', 'wlroots-0.20', 'wayland-server'], env=env, text=True))
xml = Path(subprocess.check_output(['pkg-config', '--variable=pkgdatadir', 'wayland-protocols'], text=True).strip()) / 'staging/drm-lease/drm-lease-v1.xml'
with tempfile.TemporaryDirectory(prefix='aqueous-drm-lease-protocol-') as tmp:
    tmp = Path(tmp)
    for mode, name in [('server-header', 'drm-lease-v1-protocol.h'), ('private-code', 'drm-lease-v1-protocol.c')]:
        subprocess.run(['wayland-scanner', mode, xml, tmp / name], check=True)
    (tmp / 'drm-lease-source.h').write_text((source / 'types/wlr_drm_lease_v1.c').read_text())
    subprocess.run(['cc', *sanitize_flags, '-std=c11', '-DWLR_USE_UNSTABLE', '-DWLR_PRIVATE=', '-Wall', '-Wextra', '-Werror',
                    '-Wno-unused-parameter', '-I' + str(source / 'include'), '-I' + str(tmp),
                    str(Path(__file__).parent / 'fixtures/drm-lease-protocol.c'),
                    str(tmp / 'drm-lease-v1-protocol.c'), *flags, '-o', str(tmp / 'test')], check=True, env=env)
    subprocess.run([tmp / 'test'], check=True, env=env, timeout=20)
