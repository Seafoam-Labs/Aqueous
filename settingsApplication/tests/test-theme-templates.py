#!/usr/bin/env python3
"""Render both shipped templates with real shell generators in a private profile."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='aqueous-theme-exports-') as tmp:
    base = Path(tmp)
    env = {k:v for k,v in os.environ.items() if not k.startswith(('AQUEOUS_', 'NOCTALIA_', 'DMS_')) and k not in ('WAYLAND_DISPLAY', 'DISPLAY', 'DBUS_SESSION_BUS_ADDRESS')}
    env.update(HOME=str(base), XDG_CONFIG_HOME=str(base/'config'), XDG_STATE_HOME=str(base/'state'),
               XDG_CACHE_HOME=str(base/'cache'), XDG_RUNTIME_DIR=str(base/'runtime'), GSETTINGS_BACKEND='memory')
    for part in ['config/matugen', 'state', 'cache', 'runtime', 'shell/matugen/configs', 'shell/matugen/templates']:
        (base/part).mkdir(parents=True, exist_ok=True)
    # Small deterministic wallpaper: no network or external asset dependency.
    def chunk(kind, data):
        return struct.pack('>I', len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
    pixels=b''.join(b'\0'+bytes([40+y*8,90,150])*16 for y in range(16))
    (base/'wallpaper.png').write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',16,16,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(pixels))+chunk(b'IEND',b''))
    fixture = json.loads((ROOT/'tests/fixtures/themes/noctalia.json').read_text())
    (base/'palette.json').write_text(json.dumps({k:fixture[k] for k in ['dark', 'light']}))
    def run(args):
        result = subprocess.run(args, env=env, text=True, capture_output=True, timeout=30)
        assert result.returncode == 0, (args, result.stderr, result.stdout)
    def check(path, source, mode):
        result = json.loads(path.read_text())
        assert result['version'] == 1 and result['source'] == source and result['mode'] == mode
        for variant in ['dark', 'light']:
            for role in fixture[variant]:
                value = result[variant][role]
                assert len(value) == 7 and value[0] == '#'
                int(value[1:], 16)
        return result
    for mode in ['dark', 'light']:
        out = base/f'noctalia-{mode}.json'
        run(['noctalia', 'theme', '--theme-json', str(base/'palette.json'), '--default-mode', mode,
             '-r', str(ROOT/'packaging/themes/noctalia.json.in')+':'+str(out)])
        result = check(out, 'noctalia', mode)
        assert result[mode] == fixture[mode]
        run(['noctalia','theme',str(base/'wallpaper.png'),'--default-mode',mode,'-r',str(ROOT/'packaging/themes/noctalia.json.in')+':'+str(out)])
        check(out,'noctalia',mode)
    # A minimal DMS shell tree keeps all generated files inside the temporary home.
    (base/'shell/matugen/configs/base.toml').write_text('[config]\n')
    (base/'shell/matugen/templates/dank.json').write_text('{"mode":"{{mode}}","colors":{"primary":{"dark":"{{colors.primary.dark.hex}}","light":"{{colors.primary.light.hex}}"}}}')
    (base/'config/matugen/config.toml').write_text('[config]\n[templates.aqueous_settings]\ninput_path = '+json.dumps(str(ROOT/'packaging/themes/dms.json.in'))+'\noutput_path = '+json.dumps(str(base/'dms.json'))+'\n')
    for mode in ['dark', 'light']:
        args = ['dms', 'matugen', 'generate', '--kind', 'hex', '--value', '#88c0d0', '--mode', mode,
                '--config-dir', str(base/'config'), '--state-dir', str(base/'state'), '--shell-dir', str(base/'shell')]
        run(args)
        check(base/'dms.json', 'dms', mode)
        image_args=args.copy();image_args[image_args.index('--kind')+1]='image';image_args[image_args.index('--value')+1]=str(base/'wallpaper.png')
        run(image_args);check(base/'dms.json','dms',mode)
        stock = {role:{variant:{'color':fixture[variant][role]} for variant in ['dark', 'light']} for role in fixture['dark']}
        stock['surface'] = stock['surface_container']
        for variants in stock.values(): variants['default'] = variants[mode]
        run(args + ['--stock-colors', json.dumps(stock)])
        result = check(base/'dms.json', 'dms', mode)
        assert result[mode]['primary'] == fixture[mode]['primary']
        run(args + ['--run-user-templates=false'])
        assert json.loads((base/'dms.json').read_text()) == result, 'disabled user templates rewrote the export'
print('Theme exports passed: Noctalia and DMS light/dark and wallpaper palettes, DMS custom colors and disabled user templates.')
