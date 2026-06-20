variable "name" { type = string }
variable "region" { type = string }
variable "size_gib" { type = number }

variable "zone" {
  type    = string
  default = null # null -> ${region}-b
}

variable "labels" {
  type    = map(string)
  default = {}
}
