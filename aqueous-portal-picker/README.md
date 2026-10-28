# Aqueous portal picker

A standalone Zig + GTK4 screen-sharing source chooser, installed as
`aqueous-portal-picker` by the Aqueous portal package.

The picker reads newline-separated source descriptions from stdin and writes
the selected original line to stdout. Cancel, Escape, or closing the window
returns no selection. It supports Wayland parent-window and activation tokens
supplied by the portal backend. Input is limited to 1 MiB and cannot contain NUL
bytes.

## Build

Requires Zig 0.17, GTK4 development packages, and pkg-config. GTK/GLib/GIO
bindings are pinned in `build.zig.zon`.

```sh
zig build -Doptimize=safe
# From the repository root:
zig build --build-file aqueous-portal-picker/build.zig -Doptimize=safe
```

The default build installs only `aqueous-portal-picker`. The `picker` step is an
alias for the same build. `-Dinstance-name=aqueous-git` or
`-Dinstance-name=aqueous-intel-git` selects a separate GTK application identity;
packaging supplies any executable suffix.

## Verification

The existing integration test uses private Broadway and D-Bus instances to
check selection, cancellation, exact source output, and input limits. It
requires Python 3, `gtk4-broadwayd`, and `dbus-daemon`.

```sh
zig build -Doptimize=safe -Dtest-hooks=true --prefix /tmp/aqueous-picker-test
python3 tests/test-picker.py /tmp/aqueous-picker-test/bin/aqueous-portal-picker
```

Test hooks are disabled by default and must remain disabled in shipped builds.
