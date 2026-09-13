#!/usr/bin/env python3
"""Run pinned DRM lease teardown/rediscovery code against synthetic KMS results."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile


def function(source, name):
    match = re.search(r'^[^\n;{}]*\b' + name + r'\([^;{]*\)\s*\{', source, re.M)
    assert match, name
    start = source.index('{', match.start())
    depth, end = 1, start + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[match.start():end] + '\n'


sanitize = '--sanitize' in sys.argv
source, prefix = (Path(p).resolve() for p in sys.argv[1:] if p != '--sanitize')
sanitize_flags = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-g'] if sanitize else []
env = dict(os.environ, PKG_CONFIG_PATH=str(prefix / 'lib/pkgconfig'), LD_LIBRARY_PATH=str(prefix / 'lib'))
flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wlroots-0.20', 'wayland-server', 'libdrm'], env=env, text=True))
contents = (source / 'backend/drm/drm.c').read_text()
with tempfile.TemporaryDirectory(prefix='aqueous-drm-lease-backend-') as tmp:
    tmp = Path(tmp)
    util = (source / 'backend/drm/util.c').read_text()
    matcher = util[util.index('static bool is_taken('):util.index('void generate_cvt_mode(')]
    (tmp / 'drm-lease-backend-functions.h').write_text(matcher + '\n'.join(function(contents, name) for name in (
        'format_nullable_crtc', 'realloc_crtcs', 'wlr_drm_create_lease',
        'scan_drm_connectors', 'scan_drm_leases', 'destroy_drm_connector',
        'wlr_drm_lease_terminate', 'handle_lease_rescan', 'drm_lease_destroy')))
    subprocess.run(['cc', *sanitize_flags, '-std=c11', '-D_GNU_SOURCE', '-DWLR_USE_UNSTABLE', '-DWLR_PRIVATE=',
                    '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                    '-I' + str(source / 'include'), '-I' + str(tmp),
                    str(Path(__file__).parent / 'fixtures/drm-lease-backend.c'), *flags,
                    '-o', str(tmp / 'test')], check=True, env=env)
    subprocess.run([tmp / 'test'], check=True, env=env, timeout=20)
