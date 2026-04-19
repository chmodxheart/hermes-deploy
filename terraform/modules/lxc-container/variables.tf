variable "name" {
  description = "Terraform-side identifier (also the default hostname). Map key from local.containers."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.name))
    error_message = "name must satisfy RFC 1123 hostname rules: lowercase, digits, hyphens, 1-63 chars, no leading/trailing hyphen."
  }
}

variable "hostname" {
  description = "DNS-style hostname applied inside the container. Defaults to var.name when null."
  type        = string
  default     = null

  validation {
    condition     = var.hostname == null || can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.hostname))
    error_message = "hostname must be null or satisfy RFC 1123 (lowercase, digits, hyphens, 1-63 chars, no leading/trailing hyphen)."
  }
}

variable "node" {
  description = "Proxmox cluster node hosting the container."
  type        = string
  nullable    = false

  validation {
    condition     = length(var.node) > 0
    error_message = "node must be a non-empty Proxmox node name."
  }
}

variable "vmid" {
  description = "Proxmox VMID for the LXC container. Required; no auto-sequencing."
  type        = number
  nullable    = false

  validation {
    condition     = var.vmid >= 100 && floor(var.vmid) == var.vmid
    error_message = "vmid must be an integer >= 100 (matches contracts/nixos-hosts.schema.json host.vmid.minimum)."
  }
}

variable "nixos_role" {
  description = "Logical role name consumed by nixos/ to pick a flake/module. No default."
  type        = string
  nullable    = false

  validation {
    condition     = length(var.nixos_role) > 0
    error_message = "nixos_role must be a non-empty string; it is a deliberate handoff decision, not a name coincidence."
  }
}

variable "template_file_id" {
  description = "Proxmox storage reference to a NixOS LXC template, 'storage:vztmpl/<filename>' form."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[^:/]+:vztmpl/[^/]+$", var.template_file_id))
    error_message = "template_file_id must be 'storage:vztmpl/<filename>' (defense-in-depth re-check; also validated at root)."
  }
}

variable "bridge" {
  description = "Proxmox bridge for net0. Defaults to 'vmbr1' per lab convention."
  type        = string
  default     = "vmbr1"

  validation {
    condition     = length(var.bridge) > 0
    error_message = "bridge must be a non-empty Proxmox bridge name."
  }
}

variable "vlan_id" {
  description = "VLAN ID for net0. Defaults to 0 for untagged."
  type        = number
  default     = 0

  validation {
    condition     = var.vlan_id == 0 || (var.vlan_id >= 1 && var.vlan_id <= 4094)
    error_message = "vlan_id must be 0 for untagged or an integer from 1 to 4094."
  }
}

variable "ipv4" {
  description = "Primary IPv4 address in CIDR form, e.g. 10.0.0.10/24. Static only; DHCP not supported."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$", var.ipv4))
    error_message = "ipv4 must be IPv4 CIDR form 'A.B.C.D/prefix' (e.g. 10.10.0.11/24)."
  }
}

variable "gateway" {
  description = "IPv4 default gateway for net0."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.gateway))
    error_message = "gateway must be a bare IPv4 address, e.g. 10.10.0.1."
  }
}

variable "mac_address" {
  description = "Stable MAC for net0. Required; never provider-generated."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", var.mac_address))
    error_message = "mac_address must match the schema pattern '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$' (e.g. BC:24:11:AA:BB:01)."
  }
}

variable "ssh_authorized_keys" {
  description = "Literal SSH public key strings injected into the bootstrap user's authorized_keys."
  type        = list(string)
  default     = []
}

variable "ssh_authorized_key_files" {
  description = "Paths to SSH public key files, read via file() and injected. ssh-agent passthrough is rejected."
  type        = list(string)
  default     = []
}

variable "rootfs_datastore" {
  description = "Proxmox storage id for the container rootfs (site-specific; no default)."
  type        = string
  nullable    = false

  validation {
    condition     = length(var.rootfs_datastore) > 0
    error_message = "rootfs_datastore is required (e.g. 'local-lvm', 'local-zfs')."
  }
}

variable "rootfs_size_gib" {
  description = "Rootfs size in GiB. Default 8 sized for a base NixOS system with /nix/store headroom."
  type        = number
  default     = 8

  validation {
    condition     = var.rootfs_size_gib >= 4 && var.rootfs_size_gib <= 1024
    error_message = "rootfs_size_gib must be between 4 and 1024 GiB."
  }
}

variable "cpu_cores" {
  description = "Number of CPU cores allocated. Default 1."
  type        = number
  default     = 1

  validation {
    condition     = var.cpu_cores >= 1 && floor(var.cpu_cores) == var.cpu_cores
    error_message = "cpu_cores must be a positive integer."
  }
}

variable "memory_mib" {
  description = "Dedicated memory in MiB. Default 1024 sized for nixos-rebuild closure evaluation."
  type        = number
  default     = 1024

  validation {
    condition     = var.memory_mib >= 128 && floor(var.memory_mib) == var.memory_mib
    error_message = "memory_mib must be a positive integer >= 128."
  }
}

variable "memory_swap_mib" {
  description = "Swap memory in MiB. Default 512."
  type        = number
  default     = 512

  validation {
    condition     = var.memory_swap_mib >= 0 && floor(var.memory_swap_mib) == var.memory_swap_mib
    error_message = "memory_swap_mib must be a non-negative integer."
  }
}

variable "start_on_boot" {
  description = "Whether the container autostarts when the Proxmox node boots. Default true."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra Proxmox tags to append. The module always prepends the 'nixos' tag."
  type        = list(string)
  default     = []
}
