# Nix packaging

This directory contains the source package and NixOS integration for Aqueous.
The initial package includes the compositor, `aqueousctl`, the Noctalia settings
helper and plugin, the session launchers, configuration defaults, and Aqueous's
private patched wlroots library. The Arch-specific `aqueous-welcome` application
is intentionally excluded because its Shelly backends install repository and
AUR packages.

## Build the package

From a Nixpkgs checkout:

```sh
nix-build -E 'with import <nixpkgs> {}; callPackage ./nix/default.nix {}'
```

With flakes, build it from a configuration repository by importing the overlay:

```nix
{
  nixpkgs.overlays = [ (import /path/to/Aqueous/nix/overlay.nix) ];
}
```

The package requires a Nixpkgs revision containing Zig 0.16 and
`wayland-protocols` 1.49 or newer.

## Enable the NixOS session

Import the module and overlay, then enable Aqueous:

```nix
{
  imports = [ /path/to/Aqueous/nix/module.nix ];
  nixpkgs.overlays = [ (import /path/to/Aqueous/nix/overlay.nix) ];

  programs.aqueous = {
    enable = true;
    package = pkgs.aqueous;
  };
}
```

The module registers the display-manager session, XWayland, UWSM, portals,
udev access, default XDG configuration, the Noctalia user service, and user
tmpfiles. `programs.aqueous.noctalia.enable = false` keeps the compositor
session without enabling the Noctalia user service or adding Noctalia to the
system package set.

## Upstreaming to Nixpkgs

Copy `default.nix` and `zig-deps.nix` to
`pkgs/by-name/aq/aqueous/`, replace the local `src` default with a tagged
`fetchFromGitHub`, and add the module plus a headless NixOS test. Keep the
patched wlroots derivation private to Aqueous: the compositor installs and uses
that exact shared library through its origin-relative runtime path.
