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
variable "region" { type = string }
variable "size_gib" { type = number }

variable "zone" {
  type    = string
  default = null # null -> regional (zoneless) disk
}

variable "labels" {
  type    = map(string)
  default = {}
}
