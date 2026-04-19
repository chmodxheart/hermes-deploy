# MinIO `langfuse` bucket + IAM setup

> Source: `.planning/phases/01-audit-substrate/01-09-PLAN.md` Wave 5,
> CONTEXT D-05 (external MinIO at `minio.samesies.gay`).
> One-time setup; rerun for disaster recovery.

## 1. Admin alias on the operator workstation

```bash
nix shell nixpkgs#minio-client
mc alias set samesies https://minio.samesies.gay <admin-access-key> <admin-secret-key>
```

Verify: `mc admin info samesies`.

## 2. Create the bucket

```bash
mc mb samesies/langfuse
mc version enable samesies/langfuse       # recommended for accidental-delete recovery
```

Langfuse writes each event/trace payload as an object under a prefix
controlled by `LANGFUSE_S3_EVENT_UPLOAD_PREFIX` (default `events/`).

## 3. Scoped IAM policy

Create `langfuse-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::langfuse",
        "arn:aws:s3:::langfuse/*"
      ]
    }
  ]
}
```

Then:

```bash
mc admin policy create samesies langfuse-rw langfuse-policy.json
```

## 4. Dedicated service user

```bash
mc admin user add samesies langfuse-svc "$(openssl rand -hex 24)"
mc admin policy attach samesies langfuse-rw --user langfuse-svc
```

Record the access-key / secret-key pair — they go into sops next.

## 5. Populate sops

Edit `secrets/mcp-audit.yaml` (after `sops -e -i`):

- `langfuse_web_env.LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID` ← `langfuse-svc`
- `langfuse_web_env.LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY` ← secret key
- `langfuse_web_env.LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT` ← `https://minio.samesies.gay`
- `langfuse_web_env.LANGFUSE_S3_EVENT_UPLOAD_BUCKET` ← `langfuse`
- `langfuse_web_env.LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE` ← `true`

Repeat for `langfuse_worker_env` — worker writes the same bucket.

## 6. Smoke test

After `nixos-rebuild switch --flake .#mcp-audit`:

```bash
ssh root@mcp-audit journalctl -u podman-langfuse-web -n 100 | grep -i s3
```

Expect `s3-storage initialised` / no auth errors. A 403 at this stage
usually means the policy wasn't attached to the user — verify with
`mc admin user info samesies langfuse-svc`.
