# modules/step-ca.nix
# Source: .planning/phases/01-audit-substrate/01-CONTEXT.md D-04 (24h ACME certs)
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Pattern 2 (canonical module body)
# Source: https://smallstep.com/docs/step-ca/configuration (ACME provisioner)
#
# Thin wrapper around the upstream nixpkgs `services.step-ca` module. Stood up
# on `mcp-audit` (co-located per RESEARCH §Claude's Discretion — no dedicated
# `mcp-ca` LXC). Issues 24-hour certs via one ACME provisioner; every NATS
# server and Vector client bootstraps its cert through that provisioner.
#
# Deliberately NOT in this module:
#   * Client-side cert-bootstrap oneshots (`nats-server-cert.service` et al.)
#     — they need `${config.networking.hostName}.samesies.gay` interpolation
#     and live in Plans 01-05 (NATS) / 01-06 (mcp-audit). See RESEARCH §P9.
#   * Inbound port carve-outs (firewall / nftables allow rules) — those are
#     per-host per CONTEXT D-11; this module stays host-agnostic.
#
# Secret binding: sops-nix materialises the intermediate-key password into
# `/run/secrets/step-ca-intermediate-pw` at boot; step-ca reads it via
# `services.step-ca.intermediatePasswordFile`. The sops key is
# `step_ca_intermediate_pw` (see secrets/mcp-audit.yaml.example line 68).
#
# PKI bootstrap: the upstream nixpkgs `services.step-ca` module does NOT run
# `step ca init` for you — it expects root + intermediate CA material to
# already exist at the configured paths. We handle this with a oneshot
# `step-ca-init.service` that runs before `step-ca.service`, detects a fresh
# install, and runs `step ca init --pki` non-interactively using the same
# intermediate password sops already materialises. Idempotent: exits early
# once `intermediate_ca.crt` exists.
{ config, lib, pkgs, ... }:
{
  services.step-ca = {
    enable = true;
    # ACME HTTP-01 challenge needs LAN reach; inbound 8443 is scoped per-host
    # in Plan 01-06's nftables rules (NATS + Vector client IPs only).
    address = "0.0.0.0";
    port = 8443;
    intermediatePasswordFile = "/run/secrets/step-ca-intermediate-pw";
    settings = {
      root = "/var/lib/step-ca/certs/root_ca.crt";
      crt = "/var/lib/step-ca/certs/intermediate_ca.crt";
      key = "/var/lib/step-ca/secrets/intermediate_ca_key";
      dnsNames = [
        "mcp-audit.samesies.gay"
        "ca.samesies.gay"
      ];
      db = {
        type = "badgerv2";
        dataSource = "/var/lib/step-ca/db";
      };
      authority = {
        provisioners = [
          {
            type = "ACME";
            name = "acme";
            # Issued cert CN must match the requested identity — mitigates a
            # malicious client requesting a spoofed CN.
            forceCN = true;
            claims = {
              defaultTLSCertDuration = "24h";
              maxTLSCertDuration = "24h";
              minTLSCertDuration = "5m";
            };
          }
        ];
      };
      tls = {
        minVersion = 1.2;
        maxVersion = 1.3;
      };
    };
  };

  # Literal "step-ca" owner/group rather than `config.services.step-ca.user`:
  # the upstream module does not expose a `.user` option, and resolving it
  # through `config` would introduce an ordering hazard on first eval.
  sops.secrets."step-ca-intermediate-pw" = {
    key = "step_ca_intermediate_pw";
    path = "/run/secrets/step-ca-intermediate-pw";
    owner = "step-ca";
    group = "step-ca";
    mode = "0400";
  };

  # One-shot PKI bootstrap. Runs before step-ca.service on a fresh install;
  # short-circuits once intermediate_ca.crt exists, so re-runs are free.
  #
  # `step ca init --pki` creates only the CA material (root + intermediate),
  # NOT a config file — the nixpkgs module owns `/etc/step-ca/ca.json`.
  # `--password-file` is accepted by `step ca init` (verified via `step ca
  # init --help`) and reuses the sops-materialised intermediate password so
  # that step-ca.service can unlock the key on subsequent starts.
  systemd.services.step-ca-init = {
    description = "Initialize step-ca PKI on first boot";
    wantedBy = [ "step-ca.service" ];
    before = [ "step-ca.service" ];
    # sops-nix runs as an activation script (not a systemd unit), so
    # /run/secrets/step-ca-intermediate-pw is materialised before any
    # unit starts — no ordering dependency needed.
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "step-ca";
      Group = "step-ca";
      # step-ca runs with state under /var/lib/step-ca; init writes into
      # certs/ and secrets/ subdirectories, which do not yet exist.
      StateDirectory = "step-ca";
      StateDirectoryMode = "0700";
    };
    path = [ pkgs.step-cli ];
    script = ''
      set -euo pipefail
      if [ -f /var/lib/step-ca/certs/intermediate_ca.crt ]; then
        echo "step-ca PKI already initialised; skipping"
        exit 0
      fi
      echo "initialising step-ca PKI at /var/lib/step-ca"
      export STEPPATH=/var/lib/step-ca
      step ca init --pki \
        --name "samesies-ca" \
        --dns "ca.samesies.gay" \
        --dns "mcp-audit.samesies.gay" \
        --address ":8443" \
        --provisioner "acme" \
        --password-file /run/secrets/step-ca-intermediate-pw
    '';
  };

  # Export the root CA cert to a world-readable path for co-located
  # consumers on this host (Vector on mcp-audit). Remote hosts get the
  # root via sops after it's been manually encrypted post-init. Runs
  # after step-ca-init has produced /var/lib/step-ca/certs/root_ca.crt
  # and re-runs idempotently — `install -m 0644` handles the copy.
  systemd.services.step-ca-root-export = {
    description = "Publish step-ca root cert to /var/lib/step-ca-root";
    wantedBy = [ "multi-user.target" ];
    after = [ "step-ca-init.service" ];
    requires = [ "step-ca-init.service" ];
    before = [ "vector-client-cert.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "step-ca-root";
      StateDirectoryMode = "0755";
    };
    script = ''
      set -euo pipefail
      install -m 0644 \
        /var/lib/step-ca/certs/root_ca.crt \
        /var/lib/step-ca-root/root_ca.pem
    '';
  };
}
