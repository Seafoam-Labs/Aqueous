{ config, lib, pkgs, ... }:
let
  cfg = config.programs.aqueous;
  selected = if cfg.shell != null then cfg.shell
    else if cfg.noctalia.enable != null then (if cfg.noctalia.enable then "noctalia" else "none")
    else null;
  components = if cfg.package == null then null else cfg.package;
  available = components != null && components ? core && components ? session && components ? portal;
  session = if available then components.session else null;
  runtime = if available then "${session}/lib/aqueous/session-runtime.sh" else "";
  shellPackage = if cfg.shellPackage != null then cfg.shellPackage
    else if selected == "noctalia" then pkgs.noctalia-shell else null;
  shellCommand = if selected == "dms" then "${shellPackage}/bin/dms run --session"
    else if selected == "pearl" then "${shellPackage}/bin/pearl"
    else "${shellPackage}/bin/noctalia --daemon";
  hasShell = selected != null && selected != "none" && shellPackage != null;
in {
  options.programs.aqueous = {
    enable = lib.mkEnableOption "the managed Aqueous Wayland session";
    package = lib.mkOption {
      type = with lib.types; nullOr package;
      default = if pkgs ? aqueous then pkgs.aqueous else null;
      description = "Desktop composition with core/session/portal passthru; package-only users should install pkgs.aqueousCore instead.";
    };
    shell = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "none" "pearl" "dms" "noctalia" ]);
      default = null;
      description = "Explicit system session default. Existing per-user session.toml takes precedence; null requires a migration choice before activation.";
    };
    shellPackage = lib.mkOption {
      type = with lib.types; nullOr package;
      default = null;
      description = "Selected shell package. Required for Pearl and DMS; Noctalia defaults to pkgs.noctalia-shell.";
    };
    noctalia.enable = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Deprecated explicit mapping: true selects Noctalia, false selects none. Set shell instead.";
    };
    welcome.enable = lib.mkEnableOption "the optional GTK welcome application";
    extraPackages = lib.mkOption {
      type = with lib.types; listOf package;
      default = [ ];
      description = "Additional packages installed for the explicitly enabled session.";
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      { assertion = available; message = "programs.aqueous.package must be the component desktop composition from the Aqueous overlay."; }
      { assertion = selected != null; message = "Choose programs.aqueous.shell explicitly (noctalia, dms, pearl or none). The previous implicit Noctalia default is no longer applied; select noctalia to keep it."; }
      { assertion = cfg.noctalia.enable == null || cfg.shell == null || cfg.shell == (if cfg.noctalia.enable then "noctalia" else "none"); message = "Conflicting programs.aqueous.shell and deprecated noctalia.enable values."; }
      { assertion = selected == null || selected == "none" || shellPackage != null; message = "Set programs.aqueous.shellPackage for the selected shell."; }
    ];
    warnings = lib.optional (cfg.noctalia.enable != null) "programs.aqueous.noctalia.enable is deprecated; set programs.aqueous.shell explicitly.";
    environment.systemPackages = lib.optionals available ([ components.core session components.portal ]
      ++ builtins.attrValues components.integrations
      ++ lib.optional cfg.welcome.enable components.welcome)
      ++ lib.optional hasShell shellPackage
      ++ [ pkgs.uwsm pkgs.grim pkgs.slurp pkgs.wl-clipboard pkgs.xdg-desktop-portal-gtk ]
      ++ cfg.extraPackages;
    services.displayManager.sessionPackages = lib.optional available session;
    programs.uwsm.enable = true;
    programs.xwayland.enable = true;
    services.pipewire = { enable = true; wireplumber.enable = true; };
    # No uaccess rule: the compositor uses logind/seatd for seat access.
    systemd.packages = lib.optionals available [ session components.portal ];
    environment.sessionVariables = {
      AQUEOUS_UNIT_DIR = "/etc/systemd/user";
      AQUEOUS_SYSCONFDIR = "/etc";
      AQUEOUS_SHARE_DIR = "/run/current-system/sw/share/aqueous";
      AQUEOUS_DMS_CHOOSER = lib.mkIf available "${components.integrations.dms}/lib/aqueous/aqueous-dms-portal-chooser";
    };
    environment.etc = lib.mkIf available ({
      "xdg/aqueous/wm.toml".source = "${session}/share/aqueous/wm.toml";
      "xdg/aqueous/outputs.toml".source = "${session}/share/aqueous/outputs.toml";
      "xdg/aqueous/session.toml".text = ''
        version = 1
        shell = "${if selected == null then "none" else selected}"
      '';
      "xdg/uwsm/env-aqueous".source = "${session}/etc/xdg/uwsm/env-aqueous";
      "xdg/xdg-desktop-portal-aqueous/config".source = "${session}/etc/xdg/xdg-desktop-portal-aqueous/config";
    } // lib.optionalAttrs (selected == "dms") {
      "xdg/quickshell/dms-plugins/aqueousPortal".source = "${components.integrations.dms}/share/aqueous/dms-plugins/aqueousPortal";
      "xdg/quickshell/dms-plugins/aqueousSettingsAppearance".source = "${components.integrations.dms}/share/aqueous/dms-plugins/aqueousSettingsAppearance";
    } // lib.optionalAttrs cfg.welcome.enable {
      "xdg/autostart/org.aqueous.Welcome.desktop".source = "${components.welcome}/etc/xdg/autostart/org.aqueous.Welcome.desktop";
    });
    xdg.portal = {
      enable = true;
      extraPortals = lib.optionals available [ components.portal ] ++ [ pkgs.xdg-desktop-portal-gtk ];
      config.aqueous = {
        default = [ "gtk" ];
        "org.freedesktop.impl.portal.ScreenCast" = [ "aqueous" ];
        "org.freedesktop.impl.portal.Screenshot" = [ "aqueous" ];
      };
    };
    systemd.user.services = lib.mkIf available ({
      aqueous-shell-failed = {
        description = "Report failed Aqueous shell startup";
        serviceConfig = { Type = "oneshot"; ExecStart = "${runtime} recover"; };
      };
    } // lib.optionalAttrs hasShell {
      "aqueous-${selected}" = {
        description = "Selected Aqueous desktop shell";
        wantedBy = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        after = [ "graphical-session.target" ];
        before = [ "xdg-desktop-autostart.target" ];
        unitConfig = { Requisite = "graphical-session.target"; OnFailure = "aqueous-shell-failed.service"; };
        environment = { AQUEOUS_UNIT_DIR = "/etc/systemd/user"; AQUEOUS_SYSCONFDIR = "/etc"; };
        path = [ shellPackage pkgs.bash pkgs.jq ];
        serviceConfig = {
          Type = if selected == "dms" then "dbus" else if selected == "noctalia" then "forking" else "simple";
          ExecCondition = "${runtime} condition ${selected}";
          ExecStart = if selected == "pearl" then "${components.core}/bin/aqueous-activity-launch ${shellCommand}" else shellCommand;
          Restart = "on-failure";
          RestartSec = 2;
          Slice = "app-graphical.slice";
        } // lib.optionalAttrs (selected == "dms") { BusName = "org.freedesktop.Notifications"; }
          // lib.optionalAttrs (selected == "pearl") { KillMode = "process"; };
      };
    });
    systemd.user.tmpfiles.rules = [
      "d %h/.cache/aqueous 0700 - - -"
      "d %h/.config/aqueous 0700 - - -"
      "d %h/.local/state/aqueous 0700 - - -"
    ];
  };
}
