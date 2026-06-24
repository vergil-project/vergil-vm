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

variable "provision_env" { type = string } # rendered /etc/vergil/provision.env body

variable "labels" {
  type    = map(string)
  default = {}
}
