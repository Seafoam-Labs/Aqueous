# Aqueous configuration helper

`aqueous-config` is the canonical configuration backend for Pearl and other
clients. The retired `aqueous-settings` GUI, its desktop entry, palette templates,
shortcut-capture code and Quark dependency have been removed. The historical
`settingsApplication/` directory is retained so existing build paths and source
references continue to work. Pearl is supplied separately.

The helper preserves protocol 1 and the existing version, snapshot, validate,
apply, raw, stdin-request and shell-mode interfaces. It retains schema fields,
unknown TOML/comments, generation checks, explicit user-override authorization,
backups, canonical reload acknowledgement, cursor and typography synchronization.
The [T11 additions and remaining work](docs/T11.md) are unchanged by GUI retirement.

## Build and package

From this directory in a full Aqueous checkout, using Zig 0.16.0:

```sh
zig build -Doptimize=ReleaseSafe
zig build test test-driver
DESTDIR=/tmp/aqueous-config-stage PREFIX=/usr \
  AQUEOUSCTL_BINARY=/path/to/matching/aqueousctl packaging/install.sh
```

The default build installs only `aqueous-config`; `config` is still an explicit
build step and `test-driver` is opt-in. The older `-Dhelper-only=true` and
`-Dmodel-only=true` options remain accepted. No GUI dependencies are fetched.
The installer stages the helper, matching `aqueousctl`, licenses and backend
contract documentation. It does not install a launcher or enable a shell plugin.
See [runtime dependencies and installation details](docs/HELPER.md).

Distribution packages that support legacy DMS typography clients explicitly use
`packaging/install.sh --with-dms-appearance`. That optional backend bridge has no
settings UI and does not enable itself. `--shell none` remains the Pearl contract;
`--shell dms` and `--shell noctalia` remain available for existing clients.

## Interfaces

```sh
aqueous-config version --json
aqueous-config snapshot --shell none
aqueous-config raw --shell none --file outputs
aqueous-config validate --shell none --request request.json
aqueous-config apply --shell none --request -
```

Requests retain `protocol: 1` and the original `expected_generation` from the
snapshot. Structured changes and raw files use the same backend. Validation is
read-only. Apply saves and requests reload once; clients must not add an
unconditional second reload. The default Apply response remains snapshot-shaped;
`--result v1` opts into separate save/reload/toolkit results. Neither response
shape currently provides a native display transaction or durable operation receipt.

## Verification

```sh
zig build test test-driver
tests/test-backend.sh
tests/test-packaging.sh
tests/backend/test-t11.sh
python3 tests/test-retirement.py
```

Set `AQUEOUS_CONFIG_BINARY` and `AQUEOUSCTL_BINARY` when testing a non-default
build prefix. Backend regressions and packaging checks use temporary files;
T11 integration uses a private bus. Tests never install into a running desktop.
GUI-only interaction tests were removed, while subprocess timeout/output-limit
coverage and all canonical backend regressions remain.

## Existing installations

Package upgrades remove package-owned GUI files. No migration script deletes
per-user configuration, old GUI preferences, drafts, caches or backups. Remove
custom launch bindings targeting `aqueous-settings` and use Pearl. Source changes
and DESTDIR tests do not uninstall software from the current session.
