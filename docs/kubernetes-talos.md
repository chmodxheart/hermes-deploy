# Kubernetes/Talos Source of Truth

Kubernetes and Talos state remain owned by the external clustertool GitOps repo.
This homelab repo references that source through the pinned `external/clustertool`
submodule, `scripts/kubernetes-talos.sh`, and this runbook; it does not copy
manifests, Talos secrets, Flux deploy keys, or decrypted Kubernetes SOPS values.

## Current Source

- **Active source:** `external/clustertool`
- **Upstream source:** `git@github.com:escidmore/clustertool.git`
- **Pinned commit:** `5db9b7f630320e9ae4c2adbc631c327c998f0d25`
- **Homelab integration:** referenced as a pinned submodule for browsing,
  inventory, and safe verification.

The active cluster layout under `external/clustertool/clusters/main/` includes
`clusterenv.yaml`, Talos generated and patch files, and Kubernetes Flux/Kustomize
trees under `clusters/main/kubernetes`. Durable Kubernetes changes remain
clustertool-owned through Git and Flux.

## Homelab Wrapper Commands

Run these from the homelab repo root:

```bash
./scripts/kubernetes-talos.sh repo-path
./scripts/kubernetes-talos.sh static
./scripts/kubernetes-talos.sh verify
./scripts/kubernetes-talos.sh live
./scripts/kubernetes-talos.sh flux-status
./scripts/kubernetes-talos.sh talos-status
CLUSTERTOOL_REPO=/path/to/clustertool ./scripts/kubernetes-talos.sh verify
```

`verify` is the safe default. It first checks the submodule structure and SOPS
metadata without decrypting secrets, then runs read-only live checks when local
`flux`, `kubectl`, `talosctl`, and cluster context are available. Missing live
tools or context print `SKIP:` lines instead of failing the static verification.

## Updating The Pinned Submodule

Refresh the external source explicitly when homelab should see a newer
clustertool state:

```bash
git -C external/clustertool fetch
git -C external/clustertool checkout <commit>
./scripts/kubernetes-talos.sh verify
```

Then create a homelab commit containing only the submodule pointer and related
docs or inventory changes. Do not edit Kubernetes manifests from the homelab
repo; make durable cluster changes in clustertool, push them there, let Flux
reconcile them, and then update this pinned reference when needed.

## Flux And Kustomize Workflow

Flux continuously reconciles the clustertool Git state into the cluster. Standard
application folders follow the clustertool pattern:

```text
clusters/main/kubernetes/{group}/{app}/app/
├── helm-release.yaml
├── kustomization.yaml
└── namespace.yaml
```

Use the homelab wrapper for read-only inspection from this repo. Use clustertool
for durable Flux/Kustomize/HelmRelease edits and its own verification workflow.
Do not run manual `kubectl apply` for resources that remain GitOps-managed.

## Talos Handling

Talos configuration and generated secrets live under
`external/clustertool/clusters/main/talos`. Homelab verification may check that
the Talos tree exists and that generated encrypted files carry SOPS metadata, but
it does not apply Talos machine configuration. Operational Talos changes belong
in clustertool with the matching Talos workflow and rollback plan.

## Secret Boundary

- normal verification does not decrypt Kubernetes SOPS files or print secret
  material.
- Static checks only verify encrypted structure and metadata, including top-level
  `sops:` markers on `*.secret.yaml`, `clusters/main/clusterenv.yaml`, and
  `clusters/main/talos/generated/talsecret.yaml`.
- Never commit `age.agekey`, Flux deploy keys, Talos secrets, plaintext Secret
  manifests, or decrypted SOPS output to homelab.
- If a secret must be edited, do it intentionally in clustertool with `sops`, then
  commit the encrypted result there and update the homelab submodule pointer.

## Ownership Rules

- Durable Kubernetes changes remain clustertool-owned through Git/Flux.
- Homelab owns the reference, wrapper, docs, and inventory context around the
  external source.
- Terraform owns Proxmox envelopes only.
- NixOS owns guest convergence only.
- Home Manager owns user-level workstation state.
- Missing live Kubernetes or Talos access should not block homelab discovery;
  static checks remain the baseline.
