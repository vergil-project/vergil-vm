variable "name" {
  type = string

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", var.name))
    error_message = "name must be RFC1035: a lowercase letter first, then lowercase alphanumerics or hyphens, no trailing hyphen."
  }

  validation {
    condition     = length(var.name) <= 58
    error_message = "name must be <= 58 chars so every derived Azure resource name stays within limits."
  }
}

variable "zone" { type = string }
variable "instance_type" { type = string }

# The volume module's managed-disk resource ID. Validated so a malformed value fails
# fast at plan rather than producing an empty resource group via a bad split.
variable "volume_id" {
  type = string

  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Compute/disks/[^/]+$", var.volume_id))
    error_message = "volume_id must be an Azure managed-disk resource ID (/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/disks/<name>)."
  }
}

variable "ssh_user" { type = string }
variable "ssh_public_key" { type = string }

variable "nested" {
  type    = bool
  default = true
}

variable "boot_disk_gib" {
  type    = number
  default = 30
}

# Storage SKU for the ephemeral OS disk (os_disk.storage_account_type). The default is
# the value the module always hard-coded, so behaviour is unchanged. The values are
# Azure-native, like instance_type; the GCP module takes GCE disk types under the same
# interface name. Allowed values and the forces-replacement note come from the azurerm
# docs. Premium_* SKUs need a VM size that supports premium storage (the "s" sizes):
#   https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/linux_virtual_machine#storage_account_type-1
#
# Changing this value replaces the VM. That is acceptable because the OS disk is
# ephemeral by design; the persistent volume is unaffected.
variable "boot_disk_type" {
  type    = string
  default = "StandardSSD_LRS"

  validation {
    condition     = contains(["Standard_LRS", "StandardSSD_LRS", "Premium_LRS", "StandardSSD_ZRS", "Premium_ZRS"], var.boot_disk_type)
    error_message = "boot_disk_type must be one of Standard_LRS, StandardSSD_LRS, Premium_LRS, StandardSSD_ZRS, Premium_ZRS."
  }
}

variable "provision_env" { type = string } # rendered /etc/vergil/provision.env body

variable "labels" {
  type    = map(string)
  default = {}
}
