#!/usr/bin/env bash
# Co-installable development core, with a private GNU-style install prefix.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$root/packaging/components/common.sh"
case ${1:-} in git|intel-git) channel=$1;; *) aq_die 'Usage: stage.sh git|intel-git';; esac
instance=aqueous-$channel
package=aqueous-core-$channel
prefix=${PREFIX:-/usr}
[[ $prefix =~ ^/[a-zA-Z0-9_./+-]+$ && /$prefix/ != */../* ]] || aq_die 'Use an absolute, shell-safe PREFIX'
private=$prefix/lib/$instance
destination=${DESTDIR:?Set DESTDIR to an empty staging root}
compositor=${AQUEOUS_COMPOSITOR_DIST:?Set AQUEOUS_COMPOSITOR_DIST}
helper=${AQUEOUS_CONFIG_DIST:?Set AQUEOUS_CONFIG_DIST}
for build in "$compositor" "$helper"; do
    jq -e --arg instance "$instance" '. == {schema:1,instance:$instance}' "$build/share/aqueous/build-instance.json" >/dev/null || aq_die 'Wrong build instance; rebuild compositor and helper with -Dinstance-name'
done
AQUEOUS_CONFIG_BINARY="$helper/bin/aqueous-config" AQUEOUSCTL_BINARY="$compositor/bin/aqueousctl" \
    PREFIX="$private" "$root/packaging/stage-component.sh" core
copy() { install -Dm"${3:-644}" -- "$1" "$destination$2"; }
copy "$compositor/share/aqueous/build-instance.json" "$private/build-instance.json"
sed "s/@INSTANCE@/$instance/g" "$root/packaging/git/run.sh" > "$destination$private/run"
chmod 755 "$destination$private/run"
install -d "$destination$prefix/bin" "$destination$prefix/share/man/man1" "$destination$prefix/share/pkgconfig" "$destination$prefix/share/doc/$package" "$destination$prefix/share/licenses/$package"
for command in aqueous aqueousctl aqueous-config; do
    cat > "$destination$prefix/bin/$command-$channel" <<LAUNCHER
#!/bin/sh
exec "$private/run" "$command" "\$@"
LAUNCHER
    chmod 755 "$destination$prefix/bin/$command-$channel"
    cat > "$destination$prefix/share/man/man1/$command-$channel.1" <<MAN
.TH ${command^^}-${channel^^} 1
.SH NAME
$command-$channel \- Aqueous development $command command
.SH SYNOPSIS
.B $command-$channel
.RI [ arguments ]
.SH DESCRIPTION
Runs the private $instance toolchain. Stable Aqueous binaries and services are unchanged.
Default configuration is in \$XDG_CONFIG_HOME/$instance (or ~/.config/$instance).
Configuration transaction state is in \$XDG_STATE_HOME/$instance.
To target an existing development compositor from another desktop, explicitly set
AQUEOUS_GIT_WAYLAND_DISPLAY and AQUEOUS_GIT_SOCKET.
.SH SEE ALSO
The complete upstream manuals and helper protocol documentation are installed
under $prefix/lib/$instance/share/man and $prefix/share/doc/$package.
MAN
done
# Give protocols/pkg-config/docs their own public identities as well.
mv "$destination$private/share/aqueous-protocols" "$destination$prefix/share/$instance-protocols"
sed -e "s|^prefix=.*|prefix=$prefix|" -e "s|/aqueous-protocols|/$instance-protocols|g" -e "s|^Name:.*|Name: $instance-protocols|" \
    "$destination$private/share/pkgconfig/aqueous-protocols.pc" > "$destination$prefix/share/pkgconfig/$instance-protocols.pc"
rm "$destination$private/share/pkgconfig/aqueous-protocols.pc"
mv "$destination$private/share/doc/aqueous-core" "$destination$prefix/share/doc/$package/core"
mv "$destination$private/share/doc/aqueous-config" "$destination$prefix/share/doc/$package/config"
mv "$destination$private/share/licenses/aqueous-core/compositor" "$destination$prefix/share/licenses/$package/compositor"
mv "$destination$private/share/licenses/aqueous-config" "$destination$prefix/share/licenses/$package/config"
copy "$root/docs/git-packages.md" "$prefix/share/doc/$package/GIT-PACKAGES.md"
