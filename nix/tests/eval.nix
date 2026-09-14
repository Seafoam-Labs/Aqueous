# nix-instantiate --eval --strict --arg nixpkgs /path/to/nixpkgs nix/tests/eval.nix
{ nixpkgs }:
let
  evaluate = settings: (import (nixpkgs + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [ ../module.nix {
      nixpkgs.overlays = [ (import ../overlay.nix) ];
      system.stateVersion = "26.05";
      boot.loader.grub.enable = false;
      fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
      programs.aqueous = settings;
    } ];
  });
  check = settings:
    let evaluated = evaluate settings;
        cfg = evaluated.config;
        lib = evaluated.pkgs.lib;
        own = builtins.filter (a: lib.hasInfix "programs.aqueous" a.message) (builtins.filter (a: !a.assertion) cfg.assertions);
    in {
      accepted = builtins.all (a: a.assertion) own;
      warnings = builtins.filter (w: lib.hasInfix "programs.aqueous" w) cfg.warnings;
    };
  implicit = check { enable = true; };
  none = check { enable = true; shell = "none"; };
  noctalia = check { enable = true; shell = "noctalia"; };
  legacy = check { enable = true; noctalia.enable = true; };
  conflict = check { enable = true; noctalia.enable = false; shell = "noctalia"; };
  pearlMissing = check { enable = true; shell = "pearl"; };
  disabled = evaluate { enable = false; };
in
assert !implicit.accepted;
assert none.accepted;
assert noctalia.accepted;
assert legacy.accepted && legacy.warnings != [ ];
assert !conflict.accepted;
assert !pearlMissing.accepted;
assert !(disabled.config.systemd.user.services ? aqueous-pearl);
{
  inherit implicit none noctalia legacy conflict pearlMissing;
  core = disabled.pkgs.aqueousCore.drvPath;
  desktop = disabled.pkgs.aqueous.drvPath;
  sessionSystem = (evaluate { enable = true; shell = "noctalia"; }).config.system.build.toplevel.drvPath;
}
