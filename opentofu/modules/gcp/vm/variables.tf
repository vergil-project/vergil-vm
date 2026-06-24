variable "name" {
  type = string

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", var.name))
    error_message = "name must be RFC1035: a lowercase letter first, then lowercase alphanumerics or hyphens, no trailing hyphen."
  }

  validation {
    condition     = length(var.name) <= 58
    error_message = "name must be <= 58 chars so the derived <name>-data disk stays within GCP's 63-char limit."
  }
}
variable "zone" { type = string }
variable "instance_type" { type = string }
variable "volume_id" { type = string } # the volume module's self_link

# The in-guest login user the IAP transport SSHes in as (gcloud compute ssh
# "${ssh_user}@${host}" --tunnel-through-iap). On GCE this is the cloud-init default
# user, created at boot independent of any SSH key; gcloud injects ephemeral keys at
# connect time, so the module no longer carries a managed public key.
variable "ssh_user" { type = string }

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

# Declared only to satisfy the provider-agnostic interface contract (#250). GCP
# reaches the box over IAP, which injects ephemeral SSH keys at connect time, so
# the GCP module manages no keypair and ignores this value. Azure consumes it.
variable "ssh_public_key" {
  type    = string
  default = ""
}
