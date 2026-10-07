#!/usr/bin/env python3
"""Verify the Vulkan-only startup contract using real compositor processes."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('compositor', type=Path)
parser.add_argument('--experimental', action='store_true')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='aqueous-presentation-policy-') as directory:
    work = Path(directory)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('AQUEOUS_', 'WLR_', 'VK_')) and key not in
           ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS')}
    for name in ('runtime', 'home', 'config', 'cache', 'state'):
        (work / name).mkdir(mode=0o700)
    env.update(HOME=str(work / 'home'), XDG_RUNTIME_DIR=str(work / 'runtime'),
               XDG_CONFIG_HOME=str(work / 'config'), XDG_CACHE_HOME=str(work / 'cache'),
               XDG_STATE_HOME=str(work / 'state'), WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1',
               VK_DRIVER_FILES=str(work / 'no-vulkan-driver.json'))
    for name in ('CONFIG', 'RULES', 'OUTPUTS', 'INPUT', 'LAYOUT'):
        config = work / f'{name.lower()}.toml'
        config.write_text('')
        env[f'AQUEOUS_{name}'] = str(config)
    cases = [
        ('no Vulkan', {}, 'VulkanRendererUnavailable'),
        ('GLES cannot bypass Vulkan', {'WLR_RENDERER': 'gles2'}, 'VulkanRendererUnavailable'),
        ('Pixman cannot bypass Vulkan', {'WLR_RENDERER': 'pixman'}, 'VulkanRendererUnavailable'),
        ('invalid presentation', {'AQUEOUS_VULKAN_PRESENTATION': 'invalid'}, 'InvalidPresentationMode'),
    ]
    if not args.experimental:
        cases.append(('production gate', {'AQUEOUS_VULKAN_PRESENTATION': 'copy'},
                      'ExperimentalPresentationDisabled'))
    else:
        cases.append(('explicit device restriction', {'WLR_RENDER_DRM_DEVICE': '/no/such/render-node'},
                      'VulkanRendererUnavailable'))
    for label, extra, error in cases:
        result = subprocess.run([str(args.compositor.resolve()), '-no-xwayland', '-c', 'true'],
                                env=env | extra, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=10)
        assert result.returncode != 0 and error in result.stdout, (label, result.returncode, result.stdout)
        if label == 'explicit device restriction':
            assert 'trying software Vulkan' not in result.stdout
        print(f'PASS: {label}')
