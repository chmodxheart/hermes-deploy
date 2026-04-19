variable "virtual_environment_endpoint" {
  type        = string
  description = "Proxmox API endpoint URL."
}

variable "virtual_environment_api_token" {
  type        = string
  description = "Proxmox API token used by Terraform."
  sensitive   = true
}

variable "virtual_environment_ssh_username" {
  type        = string
  description = "PAM-backed SSH username for Proxmox file access."
}

variable "virtual_environment_insecure" {
  type        = bool
  description = "Whether to skip TLS verification for the Proxmox API endpoint."
  default     = false
}
