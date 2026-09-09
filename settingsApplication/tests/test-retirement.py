#!/usr/bin/env python3
"""Check Noctalia/Gentoo package staging and startup retirement without installation."""
import os,pathlib,subprocess,tempfile,tomllib
ROOT=pathlib.Path(__file__).resolve().parents[2]
config=tomllib.loads((ROOT/'packaging/noctalia/config.toml').read_text())
assert 'aqueous_settings' not in config['bar']['default']['start']
assert 'aqueous/settings' not in config.get('plugins',{}).get('enabled',[])
for path in ['packaging/noctalia.service','nix/module.nix']:
    assert 'enable-noctalia-plugin' not in (ROOT/path).read_text()
assert not (ROOT/'plugin').exists() and not (ROOT/'dms-plugin').exists()
with tempfile.TemporaryDirectory(prefix='aqueous-retirement-') as tmp:
    base=pathlib.Path(tmp);source=base/'src';source.mkdir();(source/'aqueous').symlink_to(ROOT)
    for relative in ['aqueous-dist/bin/aqueous','aqueous-dist/bin/aqueousctl','aqueous-dist/lib/aqueous/libwlroots-0.20.so','aqueous-settings-dist/bin/aqueous-settings','aqueous-welcome-dist/bin/aqueous-welcome','aqueous-portal-dist/usr/lib/aqueous/xdg-desktop-portal-aqueous','aqueous-portal-dist/usr/share/licenses/aqueous/xdg-desktop-portal-wlr/LICENSE','xdg-desktop-portal-wlr-0.8.4/LICENSE']:
        path=source/relative;path.parent.mkdir(parents=True,exist_ok=True);path.write_text('fixture\n');path.chmod(0o755)
    for name in ['noctalia','gentoo']:
        stage=base/name
        env=dict(os.environ,srcdir=str(source),pkgdir=str(stage),pkgname='aqueous-git',AQUEOUS_DIST=str(source),AQUEOUS_PREFIX=str(stage))
        command=['bash','-euc','source "$1"\npackage','test',str(ROOT/'gitNoctalia/PKGBUILD')] if name=='noctalia' else ['bash',str(ROOT/'scripts/gentoo-install.sh'),'install']
        subprocess.run(command,env=env,check=True,stdout=subprocess.DEVNULL)
        assert (stage/'usr/bin/aqueous-settings').exists()
        assert (stage/'usr/share/applications/org.aqueous.Settings.desktop').exists()
        assert (stage/'usr/share/aqueous/dms-plugins/aqueousSettingsAppearance/Daemon.qml').exists()
        for theme in ['dms', 'noctalia']:
            assert (stage/f'usr/share/aqueous/settings-application/themes/{theme}.json.in').exists()
        for retired in ['usr/bin/aqueous-config','usr/bin/aqueous-backend-test','usr/share/aqueous/noctalia-plugins','usr/share/aqueous/dms-plugins/aqueousSettings','usr/lib/aqueous/enable-noctalia-plugin']:
            assert not (stage/retired).exists(), (name,retired)
        print(name+': embedded application staged, retired plugin/helper assets absent')
