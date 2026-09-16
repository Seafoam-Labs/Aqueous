#!/usr/bin/env python3
"""Build the HDR/VRR reference client into a caller-selected directory."""
import argparse
from pathlib import Path
import shlex
import subprocess


def build(directory):
    directory = Path(directory).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    protocols = Path(subprocess.check_output(['pkg-config', '--variable=pkgdatadir', 'wayland-protocols'], text=True).strip())
    sources = []
    for name, relative in [('xdg-shell', 'stable/xdg-shell/xdg-shell.xml'),
                           ('color-management-v1', 'staging/color-management/color-management-v1.xml')]:
        header = directory / (name + '-client-protocol.h')
        source = directory / (name + '-protocol.c')
        subprocess.run(['wayland-scanner', 'client-header', protocols / relative, header], check=True)
        subprocess.run(['wayland-scanner', 'private-code', protocols / relative, source], check=True)
        sources.append(source)
    output = directory / 'preview-reference'
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client'], text=True))
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', '-I', directory,
                    Path(__file__).with_name('fixtures') / 'preview-reference-client.c',
                    *sources, *flags, '-lm', '-o', output], check=True)
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    print(build(parser.parse_args().directory))
