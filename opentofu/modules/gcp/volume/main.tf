locals {
  zone = coalesce(var.zone, "${var.region}-b")
}

# Persistent, long-lived data disk — the "laptop analog". Created once; the
# ephemeral VM module attaches it and is pinned to local.zone. No prevent_destroy
# guard: routine teardown runs `tofu destroy` on the VM state only, so this
# resource is never in a routine destroy plan, and the dedicated destroy-volume
# verb is confirmation-gated. A literal prevent_destroy can't be conditionalized,
# so it would also block that legitimate verb — the two-state separation plus the
# gated verb are the real guard. Resize-down is impossible on GCP disks, so a
# shrink in size_gib must be a deliberate destroy-volume, not an in-place apply.
resource "google_compute_disk" "data" {
  name   = var.name
  type   = "pd-ssd"
  zone   = local.zone
  size   = var.size_gib
  labels = var.labels
}
