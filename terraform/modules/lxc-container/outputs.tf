# Per-container host fact object shaped to contracts/nixos-hosts.schema.json v1.0.0.

output "host" {
  description = "NixOS-facing host facts for this container; conforms to contracts/nixos-hosts.schema.json host record."
  value = {
    vmid             = proxmox_virtual_environment_container.this.vm_id
    hostname         = local.resolved_hostname
    node             = var.node
    ipv4             = var.ipv4
    mac_address      = var.mac_address
    bridge           = var.bridge
    template_file_id = var.template_file_id
    ssh_user         = "root"
    tags             = local.resolved_tags
    nixos_role       = var.nixos_role
  }
}
