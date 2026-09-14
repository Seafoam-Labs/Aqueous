#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case ${1:-} in
    --helper-only|'')
        [[ $# == 0 ]] || shift
        exec "$root/packaging/install-config.sh" "$@"
        ;;
    --with-dms-appearance)
        shift
        "$root/packaging/install-config.sh" "$@"
        exec "$root/packaging/install-dms-appearance.sh"
        ;;
    *) echo 'Usage: install.sh [--helper-only|--with-dms-appearance]' >&2; exit 1 ;;
esac
