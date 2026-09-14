# Compatibility desktop facade. Use aqueousCore / core.nix for Pearl.
{ callPackage }:
(callPackage ./components.nix { }).desktop
