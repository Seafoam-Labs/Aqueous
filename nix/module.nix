{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.aqueous;
in
{
  options.programs.aqueous = {
    enable = lib.mkEnableOption "the Aqueous Wayland compositor session";

    package = lib.mkOption {
      type = with lib.types; nullOr package;
      default = if pkgs ? aqueous then pkgs.aqueous else null;
      defaultText = lib.literalExpression "pkgs.aqueous";
      description = ''
        The Aqueous package to use.
        When Aqueous is not yet in your Nixpkgs revision, set this to
        `pkgs.callPackage /path/to/Aqueous/nix { }`.
      '';
    };

    noctalia.enable = lib.mkEnableOption "the Noctalia shell and Aqueous settings plugin" // {
      default = true;
    };

    extraPackages = lib.mkOption {
      type = with lib.types; listOf package;
      default = [ ];
      example = lib.literalExpression "with pkgs; [ ghostty nemo firefox ]";
      description = "Additional packages installed for the Aqueous session.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.package != null;
        message = "programs.aqueous.package must be set until pkgs.aqueous is available";
      }
    ];

    environment.systemPackages =
      lib.optional (cfg.package != null) cfg.package
      ++ [
        pkgs.grim
        pkgs.libnotify
        pkgs.slurp
        pkgs.uwsm
        pkgs.wl-clipboard
        pkgs.xdg-desktop-portal-gtk
      ]
      ++ lib.optional cfg.noctalia.enable pkgs.noctalia-shell
      ++ cfg.extraPackages;

    services.displayManager.sessionPackages = lib.optional (cfg.package != null) cfg.package;
    programs.uwsm.enable = true;
    programs.xwayland.enable = true;

    services.pipewire = {
      enable = true;
      wireplumber.enable = true;
    };

    services.udev.packages = lib.optional (cfg.package != null) cfg.package;

    environment.etc = lib.mkIf (cfg.package != null) ({
      "xdg/aqueous/wm.toml".source = "${cfg.package}/share/aqueous/wm.toml";
      "xdg/aqueous/outputs.toml".source = "${cfg.package}/share/aqueous/outputs.toml";
      "xdg/uwsm/env-aqueous".source = "${cfg.package}/share/aqueous/uwsm/env-aqueous";
    } // lib.optionalAttrs cfg.noctalia.enable {
      "xdg/xdg-desktop-portal-aqueous/config".text = ''
        [screencast]
        chooser_type=dmenu
        chooser_cmd=${lib.getExe pkgs.noctalia-shell} dmenu -p "Select a source to share:"
      '';
    });

    xdg.portal = {
      enable = true;
      extraPortals = lib.optional (cfg.package != null) cfg.package
        ++ [ pkgs.xdg-desktop-portal-gtk ];
      config.aqueous = {
        default = [ "gtk" ];
        "org.freedesktop.impl.portal.ScreenCast" = [ "aqueous" ];
        "org.freedesktop.impl.portal.Screenshot" = [ "aqueous" ];
      };
    };

    systemd.user.targets.aqueous-session = {
      description = "Aqueous Wayland session";
      requires = [ "graphical-session.target" ];
      bindsTo = [ "graphical-session.target" ];
      before = [ "graphical-session.target" ];
    };

    systemd.user.services.noctalia = lib.mkIf (cfg.noctalia.enable && cfg.package != null) {
      description = "Noctalia shell for Aqueous";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      before = [ "xdg-desktop-autostart.target" ];
      unitConfig = {
        Requisite = "graphical-session.target";
        ConditionEnvironment = "XDG_CURRENT_DESKTOP=Aqueous";
      };
      serviceConfig = {
        Type = "forking";
        ExecStart = "${lib.getExe pkgs.noctalia-shell} --daemon";
        ExecStartPost = "${cfg.package}/libexec/aqueous/enable-noctalia-plugin";
        Restart = "on-failure";
        RestartSec = 2;
        Slice = "app-graphical.slice";
      };
    };

    systemd.user.tmpfiles.rules = [
      "d %h/.cache/aqueous 0700 - - -"
      "d %h/.config/aqueous 0700 - - -"
      "d %h/.local/state/aqueous 0700 - - -"
      "d %h/.local/state/river 0700 - - -"
    ];
  };
}
