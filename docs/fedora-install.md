# Install Aqueous from master on Fedora

Run the installer as your normal user on a mutable Fedora installation:

```sh
bash scripts/fedora-install.sh
```

The script always clones the latest `master` branch from
<https://github.com/Seafoam-Labs/Aqueous>, even if your local checkout is on a
different branch. It builds in a new directory and leaves your checkout alone.
It can also run as a standalone downloaded script; it does not need adjacent
repository files.

The installer uses sudo for DNF transactions. It installs Fedora build and
runtime dependencies, verifies the dependency archive checksums recorded on
master, and runs that checkout's `PKGBUILD` prepare, build, check, and package
functions. This reuses the maintained DMS source-package recipe without running
pacman or Arch install hooks. The resulting local `aqueous-git` RPM includes the
compositor, private patched wlroots, settings application, DMS integration,
screen-sharing backend, session entry, and configuration defaults.

Fedora must provide Zig 0.16.0 or newer and wayland-protocols 1.49 or newer.
Update your Fedora packages if dependency resolution cannot satisfy these
versions. Both x86_64 and aarch64 are accepted. Atomic desktops such as
Silverblue and Kinoite, and bootc installations, require a separate image or
layered-package workflow; this installer does not modify those hosts.

DankMaterialShell 1.6.1 or newer must be available from your enabled repositories.
If you want the upstream DMS development package, explicitly enable its COPR
through the installer:

```sh
bash scripts/fedora-install.sh --dms-git
```

That option enables `avengemedia/dms-git`, as documented in the
[DMS Fedora installation guide](https://danklinux.com/docs/dankmaterialshell/installation#fedora--centos).
Without the option, the installer uses the repositories already configured on
your machine. DNF keeps its usual transaction prompts; add `--yes` to accept
them automatically.

After installation, log out and select **Aqueous** in your display manager.
New profiles use **foot** for the terminal shortcut and **Nemo** for the file
manager shortcut, both installed from Fedora packages. Existing files in
`~/.config/aqueous/` remain yours; if an older profile still launches Ghostty,
install Ghostty separately or change `spawn_terminal` in `wm.toml` to `foot`.
RPM preserves edited system configuration with `%config(noreplace)` and may
write updated defaults as `.rpmnew` files.

## Build, update, and remove

```sh
# Build an RPM without installing Aqueous (dependencies are still installed).
bash scripts/fedora-install.sh --build-only

# Build using dependencies already installed; performs no sudo/DNF transactions.
bash scripts/fedora-install.sh --build-only --skip-deps

# Update: fetch and build current master again.
bash scripts/fedora-install.sh

# Remove the installed Aqueous RPM. Per-user configuration is retained.
sudo dnf remove aqueous-git
```

Builds, downloaded sources, and RPMs remain under
`${XDG_CACHE_HOME:-$HOME/.cache}/aqueous/fedora/build.*`. Set
`AQUEOUS_FEDORA_OUTPUT` to choose another parent directory. Each invocation uses
a fresh directory, including after failures. The script prints the resulting
RPM path, and the installed `/usr/share/doc/aqueous/master-commit` records the
exact source commit. Old build directories can be deleted when no longer needed.

This produces a local binary RPM for the Fedora release and architecture used
to build it. It is not a Fedora repository submission or an SRPM for COPR. DNF
tracks the installed files and runtime dependencies. Installing dependencies or
enabling the optional COPR remains in effect if a later build fails.

Installer orchestration can be tested without installing packages:

```sh
bash -n scripts/fedora-install.sh
python3 packaging/tests/test-fedora-installer.py
```

These tests use simulated compiler and package-manager commands. A complete
Fedora build and a graphical login are still needed to validate the resulting
desktop on a target system.
