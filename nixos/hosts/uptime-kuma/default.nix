# hosts/uptime-kuma/default.nix
# Source: .planning/phases/07-nixos-uptime-kuma-service/07-02-PLAN.md Task 1.
# Source: .planning/phases/07-nixos-uptime-kuma-service/07-CONTEXT.md D-01 D-05 D-07 D-08 D-09 D-10 D-11 D-12 D-14 D-15.
# Source: .planning/phases/07-nixos-uptime-kuma-service/07-PATTERNS.md §hosts/uptime-kuma/default.nix.
#
# Uptime Kuma LXC host identity and ingress policy. NixOS owns guest service
# convergence and host firewall state; Terraform owns the Proxmox envelope. The
# app data remains local at /var/lib/uptime-kuma and is deliberately not added
# to scratch or backup exclude lists.
{ lib, ... }:

let
  # Phase 5/6 allocation baseline for the Monitoring UI VLAN slot (D-01/D-07).
  lxcIp = "10.2.100.30";
  # D-10 permits Phase 7 HTTP health only from Evelyn's workstation source.
  workstationIp = "10.0.1.2";
  # D-11 live negative-test source. This is recorded but deliberately absent
  # from tcp/3001 accept rules below.
  wslNegativeTestIp = "10.0.1.9";
  # D-12 keeps SSH on the existing admin/bootstrap LAN scope instead of the
  # stricter service verification source.
  sshAllowlist = "10.0.1.0/24";
  uptimeKumaPort = 3001;
in
{
  imports = [ ../../modules/uptime-kuma.nix ];

  system.stateVersion = "25.11";

  services.homelabUptimeKuma = {
    enable = true;
    dataDir = /var/lib/uptime-kuma;
    port = uptimeKumaPort;
  };

  assertions = [
    {
      assertion = wslNegativeTestIp != workstationIp;
      message = ''
        WSL negative-test IP must not equal the allowed workstation IP per D-11.
      '';
    }
    {
      assertion = lxcIp == "10.2.100.30";
      message = ''
        uptime-kuma host IP must stay tied to the Phase 5/6 allocation baseline.
      '';
    }
  ];

  # --- D-09 host-owned default-deny nftables ---
  # Common.nix disables nixos-fw; this inet table is the complete input policy
  # for the host. D-10 exposes tcp/3001 only to workstationIp, while D-11's WSL
  # source remains intentionally absent for live negative verification.
  networking.nftables.tables.uptime-kuma-ingress = {
    family = "inet";
    content = ''
      chain input {
        type filter hook input priority filter; policy drop;
        ct state established,related accept
        iifname "lo" accept
        icmp type echo-request accept
        icmpv6 type { echo-request, nd-neighbor-solicit, nd-router-advert, nd-neighbor-advert } accept
        ip saddr ${sshAllowlist} tcp dport 22 accept
        ip saddr ${workstationIp} tcp dport ${toString uptimeKumaPort} accept
      }
    '';
  };
}
