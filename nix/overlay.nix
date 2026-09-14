final: _prev:
let components = final.callPackage ./components.nix { };
in {
  aqueous = components.desktop;
  aqueousCore = components.core;
  aqueousSession = components.session;
  aqueousWelcome = components.welcome;
  aqueousPortal = components.portal;
  aqueousIntegrations = components.integrations;
}
