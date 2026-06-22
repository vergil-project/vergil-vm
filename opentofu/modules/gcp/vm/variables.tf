variable "name" { type = string }
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
