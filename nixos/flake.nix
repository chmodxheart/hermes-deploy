{
  description = "Evelyn's NixOS configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    hermes-agent.url = "github:NousResearch/hermes-agent";
    hermes-agent.inputs.nixpkgs.follows = "nixpkgs";

    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      sops-nix,
      disko,
      hermes-agent,
      rust-overlay,
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ rust-overlay.overlays.default ];
      };

      mkHost =
        {
          hostName,
          modules,
        }:
        nixpkgs.lib.nixosSystem {
          specialArgs = {
            inherit inputs hostName;
          };
          modules = [
            {
              networking.hostName = hostName;
              nixpkgs.hostPlatform = system;
            }
            ./modules/common.nix
            ./users/eve.nix
            sops-nix.nixosModules.sops
          ]
          ++ modules;
        };
    in
    {
      nixosConfigurations = {
        hermes = mkHost {
          hostName = "hermes";
          modules = [
            ./profiles/lxc.nix
            ./hosts/hermes
            hermes-agent.nixosModules.default
          ];
        };
        mcp-nats01 = mkHost {
          hostName = "mcp-nats01";
          modules = [
            ./profiles/lxc.nix
            ./hosts/mcp-nats01
          ];
        };
        mcp-nats02 = mkHost {
          hostName = "mcp-nats02";
          modules = [
            ./profiles/lxc.nix
            ./hosts/mcp-nats02
          ];
        };
        mcp-nats03 = mkHost {
          hostName = "mcp-nats03";
          modules = [
            ./profiles/lxc.nix
            ./hosts/mcp-nats03
          ];
        };
        mcp-audit = mkHost {
          hostName = "mcp-audit";
          modules = [
            ./profiles/lxc.nix
            ./hosts/mcp-audit
            ./hosts/mcp-audit/vector-client.nix
          ];
        };

        # Phase-1 target: mcp-audit without Vector client. Used by
        # bootstrap-cluster.sh before the NATS cluster exists. Switch to
        # `mcp-audit` (full) after NATS creds are provisioned.
        mcp-audit-phase1 = mkHost {
          hostName = "mcp-audit";
          modules = [
            ./profiles/lxc.nix
            ./hosts/mcp-audit
          ];
        };
      };

      packages.${system} = {
        langfuse-nats-ingest = pkgs.callPackage ./pkgs/langfuse-nats-ingest { };
        otlp-nats-publisher = pkgs.callPackage ./pkgs/otlp-nats-publisher { };
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          age
          nil
          nixos-rebuild
          nixfmt-rfc-style
          sops
          ssh-to-age
          just
        ];
      };

      formatter.${system} = pkgs.nixfmt-rfc-style;

      checks.${system} =
        let
          # Every nixosConfiguration whose hostname starts with `mcp-` — the
          # audit plane (mcp-audit, mcp-nats-*, future MCP gateways).
          # Plan 01-07 uses this to iterate per-host eval-time assertions.
          mcpHosts = builtins.filter (n: nixpkgs.lib.hasPrefix "mcp-" n) (
            builtins.attrNames self.nixosConfigurations
          );
        in
        {
          # AUDIT-03 + D-11 — no audit-plane LXC accepts traffic from the
          # hermes LXC (one-way ingress posture). Delegates per-host to
          # tests/nft-no-hermes.nix, then aggregates via a gate derivation
          # whose `nativeBuildInputs` include the per-host checks — if any
          # per-host build fails, the aggregate fails with it.
          assert-no-hermes-reach =
            let
              perHost = map (
                h:
                import ./tests/nft-no-hermes.nix {
                  inherit pkgs;
                  hostConfig = self.nixosConfigurations.${h}.config;
                  hermesIp = "10.0.1.91";
                  hostName = h;
                }
              ) mcpHosts;
            in
            pkgs.runCommand "assert-no-hermes-reach" { nativeBuildInputs = perHost; } ''
              echo "assert-no-hermes-reach OK across ${toString (builtins.length perHost)} mcp-* host(s)" > $out
            '';

          # D-17 — narrow Prom carve-out. No wildcards (0.0.0.0/0, bare
          # saddr, missing saddr line) allowed in the `prom-scrape` nftables
          # table. A concrete source IP is required — modules/mcp-prom-
          # exporters.nix enforces "promSourceIp != \"\"" at eval time;
          # this check catches policy erosion (e.g. a host module widening
          # the carve-out in the future).
          assert-prom-carveout-narrow =
            let
              perHost = map (
                h:
                pkgs.runCommand "prom-carveout-narrow-${h}"
                  {
                    content = self.nixosConfigurations.${h}.config.networking.nftables.tables.prom-scrape.content or "";
                  }
                  ''
                    if [ -z "$content" ]; then
                      echo "FAIL: host ${h} has no prom-scrape table — D-17 requires a defined narrow carve-out" >&2
                      exit 1
                    fi
                    # Any wildcard saddr = fail.
                    if echo "$content" | grep -nE 'saddr[[:space:]]+(0\.0\.0\.0/0|\*)|saddr[[:space:]]*$' >&2; then
                      echo "FAIL: host ${h} prom-scrape carve-out contains a wildcard" >&2
                      exit 1
                    fi
                    # Non-empty concrete saddr required.
                    if ! echo "$content" | grep -nE 'ip saddr[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' >&2; then
                      echo "FAIL: host ${h} prom-scrape carve-out has no concrete source IP (empty carve-out = wildcard in effect)" >&2
                      exit 1
                    fi
                    echo "OK ${h}" >&2
                    touch $out
                  ''
              ) mcpHosts;
            in
            pkgs.runCommand "assert-prom-carveout-narrow" { nativeBuildInputs = perHost; } ''
              echo "assert-prom-carveout-narrow OK across ${toString (builtins.length perHost)} mcp-* host(s)" > $out
            '';

          # AUDIT-04 + D-03 — no anonymous NATS publishers + JWT resolver
          # block present. The nixpkgs services.nats module does NOT expose
          # a `configFile` option; it renders its config as a closure for
          # systemd's ExecStart. We grep `config.services.nats.settings`
          # serialized to JSON — the resolver block + any future
          # `allow_anonymous` toggle both surface there.
          nats-no-anonymous =
            let
              natsHosts = builtins.filter (n: nixpkgs.lib.hasPrefix "mcp-nats-" n) (
                builtins.attrNames self.nixosConfigurations
              );
              perHost = map (
                h:
                let
                  cfg = self.nixosConfigurations.${h}.config;
                  settingsJson = builtins.toJSON (cfg.services.nats.settings or { });
                in
                pkgs.runCommand "nats-no-anonymous-${h}"
                  {
                    inherit settingsJson;
                    natsEnabled = if (cfg.services.nats.enable or false) then "1" else "0";
                  }
                  ''
                    if [ "$natsEnabled" != "1" ]; then
                      echo "FAIL: host ${h} has services.nats.enable = false — expected on mcp-nats-*" >&2
                      exit 1
                    fi
                    # D-03: any `allow_anonymous` field with a truthy value
                    # (JSON boolean `true` or string `"true"`) fails.
                    if echo "$settingsJson" | grep -qE '"allow_anonymous"[[:space:]]*:[[:space:]]*(true|"true")'; then
                      echo "FAIL: host ${h} NATS settings include allow_anonymous = true" >&2
                      exit 1
                    fi
                    # D-03: the JWT `full` resolver block must be present.
                    # Rendered JSON: "resolver":{"type":"full",...}
                    if ! echo "$settingsJson" | grep -qE '"resolver"[[:space:]]*:[[:space:]]*\{[^}]*"type"[[:space:]]*:[[:space:]]*"full"'; then
                      echo "FAIL: host ${h} NATS settings missing JWT resolver block (resolver.type = full)" >&2
                      exit 1
                    fi
                    echo "OK ${h}" >&2
                    touch $out
                  ''
              ) natsHosts;
            in
            pkgs.runCommand "nats-no-anonymous" { nativeBuildInputs = perHost; } ''
              echo "nats-no-anonymous OK across ${toString (builtins.length perHost)} mcp-nats-* host(s)" > $out
            '';

          # FOUND-06 + D-12 — every mcp-* host that consumes modules/pbs-
          # excludes.nix must keep the 8-path default set as a SUBSET of
          # its actual excludePaths. Hosts may extend (per-service scratch
          # dirs) but must never shrink the baseline.
          mcp-audit-pbs-excludes =
            let
              requiredPaths = [
                "/run"
                "/var/run"
                "/proc"
                "/sys"
                "/dev"
                "/tmp"
                "/var/cache"
                "/run/secrets"
              ];
              perHost = map (
                h:
                let
                  actual = self.nixosConfigurations.${h}.config.services.mcpAuditPbs.excludePaths or [ ];
                  # lib.subtractLists a b returns [b - a]; we want [required - actual] = missing.
                  missing = nixpkgs.lib.subtractLists actual requiredPaths;
                in
                if missing == [ ] then
                  pkgs.runCommand "pbs-excludes-${h}-ok" { } ''
                    echo 'OK ${h}' >&2
                    touch $out
                  ''
                else
                  throw "mcp-audit-pbs-excludes: host '${h}' is missing required PBS excludes: ${builtins.toJSON missing}"
              ) mcpHosts;
            in
            pkgs.runCommand "mcp-audit-pbs-excludes" { nativeBuildInputs = perHost; } ''
              echo "mcp-audit-pbs-excludes OK across ${toString (builtins.length perHost)} mcp-* host(s)" > $out
            '';

          # D-04 — step-ca issues 24h TLS certs (default AND max). Meaningful
          # only on hosts with services.step-ca.enable = true. Wave 3 has no
          # such host (mcp-audit lands in Plan 01-08 with step-ca co-located),
          # so the filter yields [] and the check passes vacuously. Once
          # Plan 01-08 lands the co-located step-ca, this check activates
          # automatically — any deviation from "24h" throws at eval time.
          step-ca-cert-duration-24h =
            let
              caHosts = builtins.filter (
                n: (self.nixosConfigurations.${n}.config.services.step-ca.enable or false)
              ) (builtins.attrNames self.nixosConfigurations);
              perHost = map (
                h:
                let
                  provisioners =
                    self.nixosConfigurations.${h}.config.services.step-ca.settings.authority.provisioners;
                  claims = (builtins.head provisioners).claims;
                in
                if claims.defaultTLSCertDuration == "24h" && claims.maxTLSCertDuration == "24h" then
                  pkgs.runCommand "step-ca-24h-${h}-ok" { } ''
                    echo 'OK ${h}' >&2
                    touch $out
                  ''
                else
                  throw "step-ca-cert-duration-24h: host '${h}' has defaultTLSCertDuration=${
                    claims.defaultTLSCertDuration or "unset"
                  }, maxTLSCertDuration=${claims.maxTLSCertDuration or "unset"} — D-04 requires 24h"
              ) caHosts;
            in
            pkgs.runCommand "step-ca-cert-duration-24h" { nativeBuildInputs = perHost; } ''
              echo "step-ca-cert-duration-24h OK across ${toString (builtins.length perHost)} step-ca host(s)" > $out
            '';

          # AUDIT-01 + D-06 — every virtualisation.oci-containers.containers.
          # langfuse-* image must be pinned by `@sha256:<64-hex>` digest (no
          # tag-only refs, no `:latest`). Iterates every mcp-* host's rendered
          # container attrs and asserts each `langfuse-*` image matches the
          # strict digest regex. A tag-only or `:latest` ref fails the build.
          langfuse-image-pinned-by-digest =
            let
              digestRe = "@sha256:[0-9a-f]{64}([[:space:]]|$)";
              perHost = map (
                h:
                let
                  containers = self.nixosConfigurations.${h}.config.virtualisation.oci-containers.containers or { };
                  langfuseNames = builtins.filter (n: nixpkgs.lib.hasPrefix "langfuse-" n) (
                    builtins.attrNames containers
                  );
                  images = builtins.concatStringsSep "\n" (map (n: "${n} ${containers.${n}.image}") langfuseNames);
                in
                pkgs.runCommand "langfuse-image-pinned-${h}"
                  {
                    inherit images;
                    count = toString (builtins.length langfuseNames);
                  }
                  ''
                    if [ -z "$images" ]; then
                      echo "skip ${h}: no langfuse-* oci-containers declared" >&2
                      touch $out
                      exit 0
                    fi
                    while IFS= read -r line; do
                      [ -z "$line" ] && continue
                      if ! echo "$line" | grep -qE '${digestRe}'; then
                        echo "FAIL: ${h}: $line — D-06 requires @sha256:<64-hex> digest pin" >&2
                        exit 1
                      fi
                    done <<EOF
                    $images
                    EOF
                    echo "OK ${h}: $count langfuse-* image(s) digest-pinned" >&2
                    touch $out
                  ''
              ) mcpHosts;
            in
            pkgs.runCommand "langfuse-image-pinned-by-digest" { nativeBuildInputs = perHost; } ''
              echo "langfuse-image-pinned-by-digest OK across ${toString (builtins.length perHost)} mcp-* host(s)" > $out
            '';

          # AUDIT-05 + D-14 mcp-otel.nix env-block consistency.
          # Every nixosConfiguration whose hostname begins with `mcp-` (the
          # audit plane plus every future MCP/gateway LXC) is expected to
          # import `modules/mcp-otel.nix` and therefore surface the four
          # static OTEL env vars below on config.environment.sessionVariables.
          # OTEL_RESOURCE_ATTRIBUTES is excluded because it interpolates
          # the host's networking.hostName at eval time.
          # A host that imports the module but skips an env var (or overrides
          # one to a wrong value) trips the `throw` at Nix-eval time and
          # fails `nix flake check`. In Wave 2 no `mcp-*` host exists yet, so
          # the filter yields an empty list and the check passes vacuously.
          otel-module-consistent =
            let
              expected = {
                OTEL_SEMCONV_STABILITY_OPT_IN = "gen_ai_latest_experimental";
                OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = "true";
                OTEL_EXPORTER_OTLP_ENDPOINT = "http://127.0.0.1:4318";
                OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf";
              };
              checkHost =
                host:
                let
                  sv = self.nixosConfigurations.${host}.config.environment.sessionVariables;
                  mismatches = nixpkgs.lib.filterAttrs (k: v: (sv.${k} or null) != v) expected;
                in
                if mismatches == { } then
                  "OK ${host}"
                else
                  throw "otel-module-consistent: host '${host}' is missing or has wrong OTEL env vars: ${builtins.toJSON mismatches}";
              results = builtins.concatStringsSep "\n" (map checkHost mcpHosts);
            in
            pkgs.runCommand "otel-module-consistent" { } ''
              cat > $out <<'EOF'
              ${results}
              EOF
            '';
        };
    };
}
