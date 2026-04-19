# modules/pbs-excludes.nix
# Source: .planning/REQUIREMENTS.md FOUND-06
# Source: .planning/phases/01-audit-substrate/01-CONTEXT.md D-12
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Code Examples "Common Operation 5"
#
# Reusable module — imported by every audit-plane LXC (mcp-audit, the three
# mcp-nats-*) to write a .pxar-exclude file consumed by PBS at backup time.
# Kept standalone rather than folded into mcp-audit.nix so the nats LXCs
# can consume the same option surface without dragging in Langfuse bits.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.mcpAuditPbs;
in
{
  options.services.mcpAuditPbs.excludePaths = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [
      "/run"
      "/var/run"
      "/proc"
      "/sys"
      "/dev"
      "/tmp"
      "/var/cache"
      "/run/secrets"
    ];
    description = ''
      Absolute paths that MUST NOT appear in any PBS snapshot of this host.
      Defaults match REQUIREMENTS.md FOUND-06 (decrypted-secrets-in-backup
      defense); hosts extend via `++ [ "/path/to/add" ]`.

      Rendered to /etc/vzdump.conf.d/pxar-exclude as a newline-separated
      list; PBS reads it via proxmox-backup-client's --exclude file plumbing.
    '';
    example = [
      "/run"
      "/run/secrets"
      "/var/cache"
      "/var/lib/podman/tmp"
    ];
  };

  config = {
    # Render the exclude list to /etc/vzdump.conf.d/pxar-exclude before
    # every PBS backup run. ExecStartPre on the pbs-backup unit ensures
    # the file is always up-to-date vs. the Nix-evaluated list.
    # Source: RESEARCH §Common Operation 5 lines 945-955
    systemd.services.pbs-backup = lib.mkIf (cfg.excludePaths != [ ]) {
      serviceConfig.ExecStartPre = pkgs.writeShellScript "pbs-exclude" ''
        set -euo pipefail
        install -d -m 0755 /etc/vzdump.conf.d
        cat > /etc/vzdump.conf.d/pxar-exclude <<'EOF'
        ${lib.concatStringsSep "\n" cfg.excludePaths}
        EOF
      '';
    };
  };
}
