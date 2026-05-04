# Container inventory for Phase 2. Phase 3 extends this map without changing
# the root module shape.

locals {
  containers = {
    "mcp-audit" = {
      node                     = "pm01"
      vmid                     = 705
      ipv4                     = "10.0.120.20/24"
      gateway                  = "10.0.120.1"
      mac_address              = "BC:24:11:AD:00:10"
      vlan_id                  = 1200
      bridge                   = "vmbr1"
      nixos_role               = "mcp-audit"
      rootfs_datastore         = "ceph-rbd"
      rootfs_size_gib          = 200
      cpu_cores                = 6
      memory_mib               = 12288
      tags                     = ["audit-plane", "mcp"]
      ssh_authorized_key_files = [pathexpand("~/.ssh/id_ed25519.pub")]
    },
    "uptime-kuma" = {
      node                     = "pm01"
      vmid                     = 2130
      ipv4                     = "10.2.100.30/24"
      gateway                  = "10.2.100.1"
      mac_address              = "BC:24:11:AD:21:30"
      vlan_id                  = 2100
      bridge                   = "vmbr1"
      nixos_role               = "uptime-kuma"
      nixos_deploy_enabled     = false
      rootfs_datastore         = "ceph-rbd"
      rootfs_size_gib          = 20
      cpu_cores                = 1
      memory_mib               = 1024
      tags                     = ["migration", "uptime-kuma"]
      ssh_authorized_key_files = [pathexpand("~/.ssh/id_ed25519.pub")]
    }
  }
}
