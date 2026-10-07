#!/usr/bin/env python3
"""Exercise patched Mesa WSI decisions and Venus identity preservation (no GPU)."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def function(source, name):
    match = re.search(r'\n(?:VkResult|bool)\n' + name + r'\(', source)
    assert match, name
    start = source.index('{', match.start())
    depth, end = 1, start + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[match.start():end]


source = Path(sys.argv[1])
production = function((source / 'src/virtio/vulkan/vn_wsi.c').read_text(), 'vn_wsi_init')
production += function((source / 'src/vulkan/wsi/wsi_common_drm.c').read_text(),
                       'wsi_drm_image_needs_buffer_blit')
fixture = Path(__file__).with_name('venus-wsi.c').read_text()
with tempfile.TemporaryDirectory(prefix='aqueous-venus-wsi-') as work:
    work = Path(work)
    (work / 'production.h').write_text(production)
    (work / 'test.c').write_text(fixture)
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                    str(work / 'test.c'), '-o', str(work / 'test')], check=True)
    subprocess.run([str(work / 'test')], check=True)
