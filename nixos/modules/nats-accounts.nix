# modules/nats-accounts.nix
# Source: .planning/phases/01-audit-substrate/01-CONTEXT.md D-03 (account JWTs + server-side ACLs)
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Pitfalls P8 (nsc runs ONCE, artifacts committed to sops)
# Source: .planning/phases/01-audit-substrate/01-PATTERNS.md §modules/nats-accounts.nix (artifact-as-input)
# Source: nixos/secrets/nats-operator.yaml.example (sops key schema)
# Source: nixos/hosts/hermes/default.nix lines 10-28 (sops binding pattern)
#
# Ties the NATS cluster to sops-provided operator + account artifacts.
# Sets up sops.secrets bindings for:
#   * the operator JWT (nats_operator_jwt key → /run/secrets/nats-operator-jwt)
#   * the system account public key (nats_system_account_public_key)
#   * the admin creds (nats_admin_creds — used by the stream-create oneshot
#     in mcp-audit Plan 01-08)
#   * one JWT per account in cfg.accountNames
# Then wires a nats-jwt-sync.service oneshot that copies the decrypted
# per-account JWT files into /var/lib/nats/jwt/<name>.jwt before nats.service
# starts — the JWT "full" resolver reads its store from disk.
#
# Invariants (P8):
#   * nsc is NEVER invoked at Nix build time — no runtime derivation call
#     to nsc anywhere. Artifacts are sops-encrypted INPUTS to the build,
#     not outputs OF the build. nsc runs once on Evelyn's workstation per
#     docs/ops/nats-bring-up.md (Plan 01-09) and the output JWTs/.creds
#     blobs are `sops -e`-encrypted into secrets/nats-operator.yaml.
#   * No Nix-side file reads of /run/secrets paths — they don't exist at
#     Nix evaluation time. Resolution is deferred to activation via the
#     nats-jwt-sync oneshot (shell-level file copy at service start).
#
# Deliberately NOT here (host / consumer-plan concern):
#   * Client .creds per host (bound in each host's own secrets/<host>.yaml
#     + sops.secrets — these are per-user creds under the shared AUDIT account).
#   * Firewall rules (per D-11, host module territory).
#   * Stream creation (stream-create oneshot in mcp-audit Plan 01-08).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.mcpNatsAccounts;

  # Build a sops.secrets entry for a single account JWT. All per-account
  # entries share the same shape — operator bundle file, derived key name
  # + on-disk path, nats user/group, 0400. Factored out so the listToAttrs
  # below stays readable.
  mkAccountSecret = name: {
    name = "nats-account-${name}-jwt";
    value = {
      sopsFile = cfg.sopsOperatorFile;
      key = "nats_account_${name}_jwt";
      path = "/run/secrets/nats-account-${name}-jwt";
      owner = cfg.natsUser;
      group = cfg.natsUser;
      mode = "0400";
    };
  };
in
{
  options.services.mcpNatsAccounts = {
    enable = lib.mkEnableOption "mcp NATS accounts + operator JWT + sops bindings";

    accountNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "audit" ];
      description = ''
        Accounts declared in secrets/nats-operator.yaml. Each <name> has a
        corresponding `nats_account_<name>_jwt` sops key which sops-nix
        decrypts to `/run/secrets/nats-account-<name>-jwt`. The nats-jwt-sync
        oneshot copies those files into /var/lib/nats/jwt/<name>.jwt so the
        NATS "full" resolver picks them up. The standard deployment shape is a
        single shared AUDIT account for application traffic; per-host producer
        creds and consumer creds are users under that account, not separate
        accounts.
      '';
    };

    sopsOperatorFile = lib.mkOption {
      type = lib.types.path;
      default = ../secrets/nats-operator.yaml;
      description = ''
        Path to the sops-encrypted operator bundle. Shared across all three
        mcp-nats-* LXCs (shared recipient block in .sops.yaml).
      '';
    };

    natsUser = lib.mkOption {
      type = lib.types.str;
      default = "nats";
      description = ''
        System user that owns the decrypted operator + account JWT files.
        Matches `services.nats.user` from the upstream NixOS module (default
        is also "nats") so NATS can read its own JWT store without setuid.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Bind every per-account JWT + operator JWT + system account pubkey +
    # admin creds to disk via sops-nix. The per-account entries are built
    # dynamically from cfg.accountNames; the static bundle adds the
    # operator + system account + admin creds. Keys match
    # secrets/nats-operator.yaml.example verbatim.
    sops.secrets = lib.listToAttrs (map mkAccountSecret cfg.accountNames) // {
      # NATS server reads the operator JWT at this path (see
      # modules/nats-cluster.nix `services.nats.settings.operator`).
      # The `operator:` setting takes a JWT (eyJ...), NOT an SO... seed —
      # so `nats_operator_jwt` in secrets/nats-operator.yaml is the blob
      # produced by `nsc describe operator --raw`, not the operator seed.
      "nats-operator-jwt" = {
        sopsFile = cfg.sopsOperatorFile;
        key = "nats_operator_jwt";
        path = "/run/secrets/nats-operator-jwt";
        owner = cfg.natsUser;
        group = cfg.natsUser;
        mode = "0400";
      };
      # System account public key — threaded into
      # services.mcpNatsCluster.systemAccountPublicKey by the per-host
      # module (Plan 01-06) via a wrapper reading this file at
      # activation time, or pre-filled at plan close once the real key
      # ships to secrets/nats-operator.yaml.
      "nats-system-account-pub" = {
        sopsFile = cfg.sopsOperatorFile;
        key = "nats_system_account_public_key";
        path = "/run/secrets/nats-system-account-pub";
        owner = cfg.natsUser;
        group = cfg.natsUser;
        mode = "0400";
      };
      # Admin creds — consumed by the one-time stream-create oneshot in
      # modules/mcp-audit.nix (Plan 01-08). Bound here so mcp-audit can
      # import modules/nats-accounts.nix without also pulling in the
      # services.nats server-side wrapper.
      "nats-admin-creds" = {
        sopsFile = cfg.sopsOperatorFile;
        key = "nats_admin_creds";
        path = "/run/secrets/nats-admin.creds";
        owner = cfg.natsUser;
        group = cfg.natsUser;
        mode = "0400";
      };
    };

    # Sync decrypted account JWTs into NATS' on-disk JWT store. Runs as
    # a oneshot after sops-install-secrets (so the files exist) and before
    # nats.service (so the resolver sees them on first start). RemainAfterExit
    # so downstream units see "active" rather than a perpetual restart.
    #
    # Each account file becomes /var/lib/nats/jwt/<name>.jwt. This is a
    # name-based layout (not pubkey-based) — the resolver still works in
    # `full` mode because per-server nats-account-resolver indexes by
    # the JWT's embedded `sub` claim, not by filename.
    systemd.services.nats-jwt-sync = {
      description = "Sync sops-decrypted account JWTs into NATS JWT store";
      wantedBy = [ "nats.service" ];
      before = [ "nats.service" ];
      after = [ "sops-install-secrets.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.natsUser;
        Group = cfg.natsUser;
      };
      script = ''
        set -euo pipefail
        install -d -m 0700 /var/lib/nats/jwt
        for name in ${lib.concatStringsSep " " cfg.accountNames}; do
          src="/run/secrets/nats-account-$name-jwt"
          if [ ! -f "$src" ]; then
            echo "missing $src; sops didn't decrypt this account?" >&2
            exit 1
          fi
          install -m 0400 "$src" "/var/lib/nats/jwt/$name.jwt"
        done
      '';
    };

    # Chain the sync oneshot in front of nats.service. Duplicate-keyed with
    # modules/nats-cluster.nix's own After/Requires block — NixOS merges
    # the lists, so nats.service ends up requiring both nats-server-cert
    # (from nats-cluster.nix) and nats-jwt-sync (from here).
    systemd.services.nats = {
      after = [ "nats-jwt-sync.service" ];
      requires = [ "nats-jwt-sync.service" ];
    };
  };
}
