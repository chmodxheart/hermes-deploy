# New LXC bring-up checklist

> Source: `.planning/phases/01-audit-substrate/01-09-PLAN.md` Wave 5
> Reusable for Phase-2+ hosts. Assumes flake layout from Phase 1 and
> the `sops-nix` + `ssh-to-age` tooling in `devShells.default`.

## 1. Create the LXC on Proxmox

```bash
pct create <vmid> local:vztmpl/nixos-25.11-proxmox-lxc.tar.xz \
  --hostname <new-host> \
  --net0 name=eth0,bridge=vmbr0,hwaddr=<MAC>,ip=dhcp \
  --cores 2 --memory 2048 --rootfs local-lvm:32 \
  --unprivileged 1 --features nesting=1
pct start <vmid>
```

## 2. Pin DHCP + add AD DNS

- Mikrotik → `/ip dhcp-server lease add mac-address=<MAC> address=<ip> server=samesies-lan`
- `samba-tool dns add dc1 samesies.gay <new-host> A <ip>`

## 3. Publish the host age key

```bash
ssh root@<new-host>.samesies.gay cat /etc/ssh/ssh_host_ed25519_key.pub \
  | ssh-to-age
```

Paste the resulting `age1...` into `.sops.yaml` under `keys:` and
extend the relevant `creation_rules` entry to include the new host.

Re-encrypt any existing sops files that the host should decrypt:

```bash
sops updatekeys secrets/<the-file>.yaml
```

## 4. Add the repo scaffolding

Layout convention:

- `hosts/<new-host>/default.nix` — host-specific let-bindings
  (`lxcIp`, `hermesIp` if audit-plane, Prom source, SSH allowlist),
  `imports`, and the D-11 nftables table for ingress.
- `modules/<role>.nix` — shared role module if more than one host
  will run this role. If it's a one-off, keep logic in the host file.
- `secrets/<new-host>.yaml.example` — plaintext template; copy to
  `<new-host>.yaml` and `sops -e -i`.

## 5. Register the host in `flake.nix`

```nix
<new-host> = mkHost {
  hostName = "<new-host>";
  modules = [
    ./profiles/lxc.nix
    ./hosts/<new-host>
  ];
};
```

If the host ships a derivation consumed by a systemd unit (like
`pkgs.langfuse-nats-ingest`), also wire it via
`packages.${system}.<name> = pkgs.callPackage ./pkgs/<name> { };`.

## 6. Two-stage sops bootstrap

1. On a **fresh clone** the real `secrets/<new-host>.yaml` does not exist
   yet. Flake eval reads the path import regardless of
   `validateSopsFiles`, so commit a plaintext placeholder copied from
   `<new-host>.yaml.example` (this is the pattern used by all Phase-1
   audit-plane hosts).
2. Once the host's age key is in `.sops.yaml`, populate the
   `REPLACE_ME_*` markers and run `sops -e -i secrets/<new-host>.yaml`.
   Flip `validateSopsFiles` back to its default (`true`) in the host
   module's `sops` block at the same time.

## 7. Deploy + verify

```bash
nixos-rebuild switch --flake .#<new-host> \
  --target-host root@<new-host>.samesies.gay
nix flake check   # every eval-time invariant runs against the new host
```

## 8. If the host joins the audit plane

- Import `modules/mcp-otel.nix`, `modules/vector-audit-client.nix`,
  `modules/mcp-prom-exporters.nix`, `modules/pbs-excludes.nix`.
- Add the host's IP to `auditPlaneAllowlist` in every audit-plane
  host's `let` binding (mcp-nats-*, mcp-audit).
- Redeploy the audit plane so the nftables allowlists pick up the
  new peer.
