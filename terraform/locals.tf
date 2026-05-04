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
    "mcp-nats01" = {
      node                     = "pm01"
      vmid                     = 711
      ipv4                     = "10.0.120.21/24"
      gateway                  = "10.0.120.1"
      mac_address              = "BC:24:11:AD:00:11"
      vlan_id                  = 1200
      bridge                   = "vmbr1"
      nixos_role               = "mcp-nats"
      rootfs_datastore         = "ceph-rbd"
      rootfs_size_gib          = 30
      cpu_cores                = 2
      memory_mib               = 4096
      tags                     = ["audit-plane", "nats"]
      ssh_authorized_key_files = [pathexpand("~/.ssh/id_ed25519.pub")]
    }
    "mcp-nats02" = {
      node                     = "pm02"
      vmid                     = 712
      ipv4                     = "10.0.120.22/24"
      gateway                  = "10.0.120.1"
      mac_address              = "BC:24:11:AD:00:12"
      vlan_id                  = 1200
      bridge                   = "vmbr1"
      nixos_role               = "mcp-nats"
      rootfs_datastore         = "ceph-rbd"
      rootfs_size_gib          = 30
      cpu_cores                = 2
      memory_mib               = 4096
      tags                     = ["audit-plane", "nats"]
      ssh_authorized_key_files = [pathexpand("~/.ssh/id_ed25519.pub")]
    }
    "mcp-nats03" = {
      node                     = "pm03"
      vmid                     = 713
      ipv4                     = "10.0.120.23/24"
      gateway                  = "10.0.120.1"
      mac_address              = "BC:24:11:AD:00:13"
      vlan_id                  = 1200
      bridge                   = "vmbr1"
      nixos_role               = "mcp-nats"
      rootfs_datastore         = "ceph-rbd"
      rootfs_size_gib          = 30
      cpu_cores                = 2
      memory_mib               = 4096
      tags                     = ["audit-plane", "nats"]
      ssh_authorized_key_files = [pathexpand("~/.ssh/id_ed25519.pub")]
    }
    "uptime-kuma" = {
      node        = "pm01"
      vmid        = 2130
      ipv4        = "10.2.100.30/24"
      gateway     = "10.2.100.1"
      mac_address = "BC:24:11:AD:21:30"
      vlan_id     = 2100
      bridge      = "vmbr1"
      nixos_role  = "uptime-kuma"
      # D-02: nixos_deploy_enabled  = false keeps Phase 6 envelope-only.
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
