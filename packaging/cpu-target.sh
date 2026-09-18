#!/usr/bin/env bash
# Source from package builds; keep Zig and bundled C/C++ code portable across
# Intel and AMD CPUs supporting x86-64-v3. ARM retains its baseline target.
case ${CARCH:-$(uname -m)} in
    x86_64)
        AQUEOUS_ZIG_CPU=x86_64_v3
        export CFLAGS="${CFLAGS:+$CFLAGS }-march=x86-64-v3 -mtune=generic"
        export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-march=x86-64-v3 -mtune=generic"
        ;;
    aarch64) AQUEOUS_ZIG_CPU=baseline ;;
    *) printf 'Unsupported package architecture: %s\n' "${CARCH:-$(uname -m)}" >&2; return 1 ;;
esac
