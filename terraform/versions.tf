terraform {
  required_version = "~> 1.14.0"

  # Remote state on MinIO (S3-compatible) at https://s3.samesies.gay
  # (dedicated S3 API endpoint; the web console lives at minio.samesies.gay).
  # Credentials are injected at runtime via `op run --env-file=.env.op`;
  # never put AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in this repo.
  # Uses native S3 locking (`use_lockfile`) -- no DynamoDB required.
  backend "s3" {
    bucket = "terraform"
    key    = "hermes-deploy/terraform.tfstate"
    region = "us-east-1" # MinIO ignores region; placeholder required by backend

    endpoints = {
      s3 = "https://s3.samesies.gay"
    }

    use_path_style = true
    use_lockfile   = true

    # MinIO is not AWS; disable AWS-specific validation that would otherwise fail.
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2.4"
    }

    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.102.0"
    }
  }
}
