# Root composition for Phase 2: one module instance per local.containers entry.

module "lxc_container" {
  for_each = local.containers
  source   = "./modules/lxc-container"

  name        = each.key
  hostname    = try(each.value.hostname, null)
  node        = each.value.node
  vmid        = each.value.vmid
  ipv4        = each.value.ipv4
  gateway     = each.value.gateway
  vlan_id     = try(each.value.vlan_id, 0)
  mac_address = each.value.mac_address
  nixos_role  = each.value.nixos_role

  template_file_id = var.template_file_id

  bridge = try(each.value.bridge, "main")

  rootfs_datastore = each.value.rootfs_datastore
  rootfs_size_gib  = try(each.value.rootfs_size_gib, 8)

  cpu_cores       = try(each.value.cpu_cores, 1)
  memory_mib      = try(each.value.memory_mib, 1024)
  memory_swap_mib = try(each.value.memory_swap_mib, 512)

  start_on_boot = try(each.value.start_on_boot, true)
  tags          = try(each.value.tags, [])

  ssh_authorized_keys      = try(each.value.ssh_authorized_keys, [])
  ssh_authorized_key_files = try(each.value.ssh_authorized_key_files, [])
}

# ------------------------------------------------------------------------------
# NixOS deploy step. Relaxes the ownership boundary documented in
# ../docs/ownership-boundary.md so `terraform apply` is the single operator
# command for end-to-end bring-up. Calls ../scripts/bootstrap-host.sh
# which (1) pushes the host's age key on first boot and (2) runs
# `nixos-rebuild switch --target-host`. Idempotent — re-applies are safe.
# ------------------------------------------------------------------------------

variable "hermes_repo_path" {
  description = "Absolute path to the hermes-deploy repo root (holds scripts/ and nixos/)."
  type        = string
  default     = "/home/eve/repo/hermes-deploy"
}

variable "nixos_deploy_enabled" {
  description = "If false, skip the NixOS deploy step (useful for bare provisioning runs)."
  type        = bool
  default     = true
}

resource "null_resource" "nixos_deploy" {
  for_each = var.nixos_deploy_enabled ? local.containers : {}

  depends_on = [module.lxc_container]

  triggers = {
    # Re-run whenever the container is (re)created, or on any `terraform
    # apply`. `timestamp()` forces execution on every apply so config
    # changes in the NixOS flake get picked up without a Terraform-side
    # diff. If you want to force a redeploy, run:
    #   terraform apply -replace='null_resource.nixos_deploy["mcp-audit"]'
    container_vmid = module.lxc_container[each.key].host.vmid
    rebuild_at     = timestamp()
  }

  provisioner "local-exec" {
    command     = "${var.hermes_repo_path}/scripts/bootstrap-host.sh ${each.key}"
    working_dir = var.hermes_repo_path
    environment = {
      MCP_DOMAIN = "samesies.gay"
    }
  }
}
