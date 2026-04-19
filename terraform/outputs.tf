output "nixos_hosts_contract_schema" {
  description = "Authoritative JSON schema for downstream NixOS host facts."
  value       = jsondecode(file("${path.module}/contracts/nixos-hosts.schema.json"))
}

output "nixos_hosts_contract_example" {
  description = "Example payload matching the nixos_hosts contract schema."
  value       = jsondecode(file("${path.module}/examples/nixos-hosts.example.json"))
}

output "nixos_hosts_contract_version" {
  description = "Pinned schema_version for the nixos_hosts downstream contract, sourced from the schema's schema_version.const."
  value       = jsondecode(file("${path.module}/contracts/nixos-hosts.schema.json")).properties.schema_version.const
}

output "nixos_hosts" {
  description = "Rendered nixos_hosts contract payload (schema_version 1.0.0) for Phase 2 containers."
  value = {
    schema_version = "1.0.0"
    hosts          = { for k, m in module.lxc_container : k => m.host }
  }
}
