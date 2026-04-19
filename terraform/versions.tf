terraform {
  required_version = "~> 1.14.0"

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
