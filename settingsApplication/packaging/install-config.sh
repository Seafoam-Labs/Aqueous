#!/usr/bin/env bash
# Stage only the canonical backend. Never enable desktop/shell integration.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
prefix=${PREFIX:-/usr}
destination=${DESTDIR:-}
helper=${AQUEOUS_CONFIG_BINARY:-$root/zig-out/bin/aqueous-config}
ctl=${AQUEOUSCTL_BINARY:-$root/../compositor/zig-out/bin/aqueousctl}
[[ $# == 0 ]] || { echo 'Usage: install-config.sh (PREFIX/DESTDIR/AQUEOUS_CONFIG_BINARY/AQUEOUSCTL_BINARY)' >&2; exit 1; }
[[ -x "$helper" ]] || { echo 'Build aqueous-config with zig build config -Dhelper-only=true first.' >&2; exit 1; }
[[ -x "$ctl" ]] || { echo 'Set AQUEOUSCTL_BINARY to the matching aqueousctl executable (required for reload).' >&2; exit 1; }
install -Dm755 "$helper" "$destination$prefix/bin/aqueous-config"
install -Dm755 "$ctl" "$destination$prefix/bin/aqueousctl"
install -Dm644 "$root/../compositor/LICENSES/GPL-3.0-only.txt" "$destination$prefix/share/licenses/aqueous-config/GPL-3.0-only.txt"
install -Dm644 "$root/docs/HELPER.md" "$destination$prefix/share/doc/aqueous-config/HELPER.md"
install -Dm644 "$root/docs/T11_TRANSACTIONS.md" "$destination$prefix/share/doc/aqueous-config/T11_TRANSACTIONS.md"
install -Dm644 "$root/docs/T11.md" "$destination$prefix/share/doc/aqueous-config/T11.md"
install -Dm644 "$root/docs/T11_VERIFICATION.md" "$destination$prefix/share/doc/aqueous-config/T11_VERIFICATION.md"
install -Dm644 "$root/docs/aqueous-config-additions-v1.schema.json" "$destination$prefix/share/doc/aqueous-config/aqueous-config-additions-v1.schema.json"
install -Dm644 "$root/../docs/aqueousctl-command-reference.md" "$destination$prefix/share/doc/aqueous-config/aqueousctl-command-reference.md"
install -Dm644 "$root/../compositor/protocol/aqueous-display-v1.schema.json" "$destination$prefix/share/doc/aqueous-config/aqueous-display-v1.schema.json"
