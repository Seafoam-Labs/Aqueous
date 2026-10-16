# Aqueous: standalone stable compositor

Use this [PKGBUILD](PKGBUILD) when you need the stable Aqueous compositor on
its own, such as for Pearl Greeter or a session you configure yourself.
It builds one package, `aqueous`, containing the compositor, its private
wlroots library, manual page and licenses.

The recipe does not install the desktop session, configuration helper,
portal or Pearl shell. For the complete stable Devario desktop, use
[aqueous-desktop](../aqueous-desktop/README.md).

`aqueous-core`, produced by the desktop recipe, also provides `aqueous`.
It conflicts with this standalone package because they own the same
compositor files. Install either `aqueous` or `aqueous-core`; you do not need
both to satisfy Pearl Greeter's compositor dependency.

To build, run from this directory:

```sh
shelly build --makesrcinfo --reviewed PKGBUILD > .SRCINFO
shelly build --isolated --sync-deps --check --json PKGBUILD > build-result.json
```

The recipe fetches the release tag `v${pkgver}` specified in `PKGBUILD`.
Publish that tag before building. Its package release is independent of the
desktop recipe's package release.

For development builds that can coexist with stable Aqueous, see
[aqueous-git](../aqueous-git/README.md). See the [Devario packaging guide](../README.md)
for shared build requirements and validation.
