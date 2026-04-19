variable "template_file_id" {
  description = <<-DESC
    Proxmox storage reference for a NixOS-capable LXC template artifact, expected
    in `storage:vztmpl/<filename>` form. The artifact must already exist in Proxmox
    storage (produced by `nixos-rebuild build-image --image-variant proxmox-lxc`
    and registered with content type `vztmpl`) or be created by a later Terraform
    download/upload step. This value flows into future `proxmox_virtual_environment_container`
    resources as `operating_system.template_file_id`.
  DESC
  type        = string
  nullable    = false

  validation {
    condition     = length(var.template_file_id) > 0
    error_message = "template_file_id must be a non-empty Proxmox template reference (e.g. 'local:vztmpl/nixos-25.11-proxmox-lxc.tar.xz')."
  }
}
