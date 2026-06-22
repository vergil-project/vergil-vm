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
  # "-data" suffix is load-bearing: the VM instance uses `var.name`, and its
  # initialize_params boot disk auto-takes the *instance* name. If this disk were
  # also `var.name`, instance creation fails with resourceInUseByAnotherResource
  # (the boot-disk name clashes with this attached disk). The vm module references
  # this disk by self_link, not name, so the suffix is transparent. The dispatch
  # budgets `var.name` so `<name>-data` stays within GCP's 63-char limit.
  name   = "${var.name}-data"
  type   = "pd-ssd"
  zone   = local.zone
  size   = var.size_gib
  labels = var.labels
}
