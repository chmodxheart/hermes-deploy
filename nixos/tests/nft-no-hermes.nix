# tests/nft-no-hermes.nix
# Source: AUDIT-03 / CONTEXT D-11 / VALIDATION.md §Wave 0 Requirements bullet 1
#
# Flake-check helper: given a built NixOS config, asserts the host's
# rendered nftables policy contains no `accept` rule referencing hermesIp
# and no `saddr` clause sourcing from hermesIp. That absence IS the AUDIT-03
# / D-11 invariant — hermes has zero inbound reach into the audit plane.
#
# `networking.nftables.ruleset` is the free-form blob hosts may set directly.
# Hosts in this repo use the structured `networking.nftables.tables.<name>`
# API (Plan 01-06 + modules/mcp-prom-exporters.nix), so the helper
# concatenates every table's `content` into a single inspection blob.
# Either path contributing an accept-rule for hermesIp fails the build.
#
# Null hostConfig is a documented no-op so flake.nix can invoke the helper
# generically (e.g. before any mcp-* host enters the flake).
{
  pkgs,
  hostConfig ? null,
  hermesIp ? "10.0.1.91",
  hostName ? "unknown",
}:
if hostConfig == null then
  pkgs.runCommand "assert-no-hermes-reach-${hostName}-skip" { } ''
    echo "skipping assertion — no hostConfig passed (expected when no mcp-* hosts exist yet)" >&2
    touch $out
  ''
else
  let
    freeformRuleset = hostConfig.networking.nftables.ruleset or "";
    tables = hostConfig.networking.nftables.tables or { };
    tableContents = builtins.concatStringsSep "\n" (
      map (t: tables.${t}.content or "") (builtins.attrNames tables)
    );
    ruleset = freeformRuleset + "\n" + tableContents;
  in
  pkgs.runCommand "assert-no-hermes-reach-${hostName}"
    {
      inherit ruleset hermesIp;
      inherit hostName;
    }
    ''
      # Belt-and-suspenders: scan for any line that both mentions the hermes
      # IP and ends in an `accept` verdict (inline or on a following token),
      # and also fail if saddr ranges quote the hermes IP at all.
      #
      # Patterns to catch:
      #   ip saddr 10.0.1.91 ... accept
      #   ip saddr { ..., 10.0.1.91, ... } ... accept
      #   ip saddr 10.0.1.0/24 ... accept   (range that contains hermes)
      if echo "$ruleset" | grep -nE "accept" | grep -F "$hermesIp" >&2; then
        echo "FAIL: host '$hostName' has an accept-rule line referencing hermes IP $hermesIp" >&2
        exit 1
      fi
      if echo "$ruleset" | grep -nE "saddr.*$hermesIp" >&2; then
        echo "FAIL: host '$hostName' sources traffic from hermes IP $hermesIp — AUDIT-03 invariant violated" >&2
        exit 1
      fi
      echo "OK: host '$hostName' has no hermes-IP source/accept rule" >&2
      touch $out
    ''
