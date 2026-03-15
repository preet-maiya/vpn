variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group name"
  type        = string
  default     = "ts-exit-rg"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "centralindia"
}

variable "vm_name" {
  description = "Virtual machine name"
  type        = string
  default     = "ts-exit"
}

variable "ssh_public_key" {
  description = "Optional SSH public key"
  type        = string
  default     = ""
}

variable "tailscale_auth_key" {
  description = "Tailscale auth key"
  type        = string
  sensitive   = true
}
