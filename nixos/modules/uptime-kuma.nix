# modules/uptime-kuma.nix
# Source: .planning/phases/07-nixos-uptime-kuma-service/07-CONTEXT.md D-01 (reusable module)
# Source: .planning/phases/07-nixos-uptime-kuma-service/07-CONTEXT.md D-03 (native service)
# Source: .planning/phases/07-nixos-uptime-kuma-service/07-CONTEXT.md D-04 (host-owned allowlists)
# Source: .planning/phases/07-nixos-uptime-kuma-service/07-CONTEXT.md D-16 (no app auto-update)
#
# Thin project wrapper over the upstream NixOS Uptime Kuma module. Host-specific
# source allowlists stay in host config; this module only maps the migration's
# service mechanics into `services.uptime-kuma`.
{ config, lib, ... }:
let
  cfg = config.services.homelabUptimeKuma;
in
{
  options.services.homelabUptimeKuma = {
    enable = lib.mkEnableOption "homelab Uptime Kuma service";

    # D-03 selects the native upstream NixOS module, so this wrapper exposes no
    # image option. Any future OCI fallback must use an @sha256: digest-pinned
    # image per D-13/NIX-03 instead of a mutable tag-only reference.

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = /var/lib/uptime-kuma;
      description = ''
        Local Uptime Kuma state directory inside the LXC root filesystem.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3001;
      description = ''
        TCP port for the native Uptime Kuma service. Host nftables rules own
        source scoping for this port.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = toString cfg.dataDir == "/var/lib/uptime-kuma";
        message = ''
          Phase 7 requires local /var/lib/uptime-kuma app data and forbids NFS
          or alternate app data paths per D-07.
        '';
      }
      {
        assertion = cfg.port == 3001;
        message = ''
          Phase 7 requires Uptime Kuma port 3001 per D-10 and D-15.
        '';
      }
    ];

    services.uptime-kuma = {
      enable = true;
      settings = {
        DATA_DIR = lib.mkForce (toString cfg.dataDir);
        HOST = lib.mkForce "0.0.0.0";
        PORT = lib.mkForce (toString cfg.port);
      };
    };
  };
}
