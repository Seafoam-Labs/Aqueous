#!/usr/bin/env python3
"""Run native Zig warming handlers against private Wayland/headless outputs.

Requires Zig and the compositor build dependencies. Debug safety checks and the
Zig testing allocator cover the manager and buffer lifetimes. No physical output
is opened; renderer qualification is mocked only in the unit-test binary.
"""
import argparse
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--prefix', type=Path, required=True)
args = parser.parse_args()
env = os.environ.copy()
prefix = args.prefix.resolve()
env['PKG_CONFIG_PATH'] = str(prefix / 'lib/pkgconfig') + os.pathsep + env.get('PKG_CONFIG_PATH', '')
env['LD_LIBRARY_PATH'] = str(prefix / 'lib') + os.pathsep + env.get('LD_LIBRARY_PATH', '')
subprocess.run(['zig', 'build', 'test-output-warming', '-Dman-pages=false',
                '-Dvulkan-effects=false'], cwd=ROOT, env=env, check=True)
