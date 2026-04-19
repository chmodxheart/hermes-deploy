# SAFE-01 posture:
# - unprivileged is hardcoded true. See docs/ownership-boundary.md and PITFALLS §4.
# - features { nesting = true } only. See PITFALLS §3 and §4.
# - started = true is hardcoded; start_on_boot remains configurable.

terraform {
  required_version = "~> 1.14.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.102.0"
    }
  }
}

locals {
  resolved_hostname = coalesce(var.hostname, var.name)
  all_ssh_keys = concat(
    var.ssh_authorized_keys,
    [for path in var.ssh_authorized_key_files : file(path)],
  )
  resolved_tags = concat(["nixos"], var.tags)
}

resource "proxmox_virtual_environment_container" "this" {
  node_name     = var.node
  vm_id         = var.vmid
  tags          = local.resolved_tags
  unprivileged  = true
  started       = true
  start_on_boot = var.start_on_boot

  lifecycle {
    precondition {
      condition     = length(local.all_ssh_keys) > 0
      error_message = "At least one SSH key must be supplied via ssh_authorized_keys or ssh_authorized_key_files."
    }
  }

  # NixOS LXCs need nesting, but elevated feature flags stay out of scope here.
  features {
    nesting = true
  }

  cpu {
    cores = var.cpu_cores
  }

  memory {
    dedicated = var.memory_mib
    swap      = var.memory_swap_mib
  }

  disk {
    datastore_id = var.rootfs_datastore
    size         = var.rootfs_size_gib
  }

  operating_system {
    template_file_id = var.template_file_id
    type             = "nixos"
  }

  initialization {
    hostname = local.resolved_hostname

    user_account {
      # Terraform bootstraps root access; nixos/ owns later user creation and hardening.
      keys = local.all_ssh_keys
    }

    ip_config {
      ipv4 {
        address = var.ipv4
        gateway = var.gateway
      }
    }
  }

  network_interface {
    name        = "net0"
    bridge      = var.bridge
    mac_address = var.mac_address
    vlan_id     = var.vlan_id
  }
}
