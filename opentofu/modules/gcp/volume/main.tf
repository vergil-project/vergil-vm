locals {
  zone = coalesce(var.zone, "${var.region}-b")
}

# Persistent, long-lived data disk — the "laptop analog". Created once; the
# ephemeral VM module attaches it and is pinned to local.zone. prevent_destroy is a
# backstop: routine teardown runs `tofu destroy` on the VM state only, so this
# resource is never in a destroy plan; the guard catches an accidental blanket
# destroy of the volume state. Resize-down is impossible on GCP disks, so a
# shrink in size_gib must be a deliberate destroy-volume, not an in-place apply.
resource "google_compute_disk" "data" {
  name   = var.name
  type   = "pd-ssd"
  zone   = local.zone
  size   = var.size_gib
  labels = var.labels

  lifecycle {
    prevent_destroy = true
  }
}
