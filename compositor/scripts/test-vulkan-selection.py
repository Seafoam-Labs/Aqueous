#!/usr/bin/env python3
"""Run the production candidate selector against deterministic device/driver faults."""
from pathlib import Path
import re
import resource
import shlex
import subprocess
import sys
import tempfile


def function(source, name):
    match = re.search(r'^[a-zA-Z][^\n;{}=]+\b' + name + r'\(', source, re.M)
    assert match, name
    end = source.index('{', match.start()) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[match.start():end] + '\n'


source = (Path(sys.argv[1]) / 'render/vulkan/vulkan.c').read_text()
struct = re.search(r'struct wlr_vk_renderer_candidates \{.*?\n\};', source, re.S).group()
production = struct + '\n' + '\n'.join(function(source, name) for name in (
    'vulkan_instance_destroy', 'preferred_render_device', 'wlr_vk_renderer_candidates_create',
    'wlr_vk_renderer_candidates_next', 'wlr_vk_renderer_candidates_destroy'))
flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', 'libdrm', 'vulkan'], text=True))
mutations = {
    'software-first': ('cpu ? 2 : matches ? 0 : 1', 'cpu ? 0 : matches ? 1 : 2'),
    'explicit-device-ignored': ('explicit_path && (!matches || cpu)', 'false'),
    'stop-after-first-failure': ('if (!dev) {\n\t\t\tcontinue;', 'if (!dev) {\n\t\t\treturn NULL;'),
}
with tempfile.TemporaryDirectory(prefix='aqueous-vulkan-selection-') as directory:
    work = Path(directory)
    fixture = Path(__file__).parent / 'fixtures/vulkan-selection.c'
    variants = [('plain', production), ('asan', production)]
    for name, (old, new) in mutations.items():
        assert production.count(old) == 1, name
        variants.append((name, production.replace(old, new)))
    for name, code in variants:
        (work / 'selection-functions.h').write_text(code)
        binary = work / name
        subprocess.run(['cc', '-std=c11', '-D_GNU_SOURCE', '-Wall', '-Wextra', '-Werror',
                        '-Wno-unused-parameter', '-g', '-I' + str(work), *flags,
                        *(['-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-no-pie'] if name == 'asan' else []),
                        str(fixture), '-o', str(binary)], check=True)
        result = subprocess.run([str(binary)], capture_output=True, text=True,
                                preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE, (0, 0)))
        if name in mutations:
            assert result.returncode == -6 and 'Assertion' in result.stderr, (name, result.stderr)
            print(f'PASS: negative control rejected ({name})')
        else:
            assert result.returncode == 0, (name, result.stdout, result.stderr)
            print(f'PASS: Vulkan candidate ordering, restrictions, failure continuation and ownership ({name})')
