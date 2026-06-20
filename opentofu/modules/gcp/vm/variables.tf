variable "name" { type = string }
variable "zone" { type = string }
variable "instance_type" { type = string }
variable "volume_id" { type = string } # the volume module's self_link
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

variable "ssh_source_ranges" {
  type = list(string)
  # #1706 resolves the create-initiator's origin address(es). Reject empties and the
  # any-IPv4 wildcard (no-silent-failures; never expose sshd to the internet).
  validation {
    condition     = length(var.ssh_source_ranges) > 0 && !contains(var.ssh_source_ranges, "0.0.0.0/0")
    error_message = "ssh_source_ranges must be a non-empty list and must not contain 0.0.0.0/0."
  }
}

variable "provision_env" { type = string } # rendered /etc/vergil/provision.env body

variable "labels" {
  type    = map(string)
  default = {}
}
