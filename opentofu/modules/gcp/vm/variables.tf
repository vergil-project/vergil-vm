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

# GCE disk type for the ephemeral boot disk (boot_disk.initialize_params.type). The
# default null omits the field, which preserves the module's original behaviour exactly:
# GCE then picks the machine series' default. Per the Compute Engine API reference
# (AttachedDiskInitializeParams.diskType), that is pd-standard for first- and
# second-generation series (N1, N2, ...), pd-balanced for C3/C3D/M3, and
# hyperdisk-balanced for other third-generation and all newer series (C4, N4, ...).
# A literal "pd-standard" default would therefore break the newer series, which do not
# support Standard Persistent Disk.
#   https://cloud.google.com/compute/docs/reference/rest/v1/instances
#   https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_instance#type-1
#
# Allowed values are the durable block-storage types that are valid boot disks and need
# no extra provisioning knobs the module does not expose. pd-extreme is excluded because
# it requires provisioned IOPS and only runs on a few machine series. Hyperdisk
# Extreme/Throughput/ML and Balanced HA are excluded because they are not boot-disk
# types. The type must also suit var.instance_type's machine series:
#   https://cloud.google.com/compute/docs/disks/persistent-disks#disk-types
#   https://cloud.google.com/compute/docs/disks/hyperdisks
#
# Changing this value replaces the boot disk, and so the instance. That is acceptable
# because the boot disk is ephemeral by design; the persistent volume is unaffected.
variable "boot_disk_type" {
  type    = string
  default = null

  validation {
    condition     = var.boot_disk_type == null ? true : contains(["pd-standard", "pd-balanced", "pd-ssd", "hyperdisk-balanced"], var.boot_disk_type)
    error_message = "boot_disk_type must be one of pd-standard, pd-balanced, pd-ssd, hyperdisk-balanced (or null for the machine series' default)."
  }
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
