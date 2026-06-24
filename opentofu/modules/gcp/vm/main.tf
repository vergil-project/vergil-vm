locals {
  # Indent the multi-line provision.env body to sit under cloud-init's `content: |`
  # (6-space content indent), then splice it in via replace(). We deliberately do NOT
  # use templatefile(): the generated cloud-init.yaml inlines provision scripts that
  # contain shell ${...}, which templatefile would try to interpret as Terraform.
  provision_env_block = replace(var.provision_env, "\n", "\n      ")
  user_data           = replace(file("${path.module}/cloud-init.yaml"), "@@PROVISION_ENV@@", local.provision_env_block)

  # Google's fixed Identity-Aware Proxy (IAP) TCP-forwarding source range. IAP
  # terminates the operator's connection and originates the tunnel to the instance's
  # internal IP from within this Google-owned block, so the firewall trusts a module
  # constant — never an operator's (NAT-masked, unknowable) public address.
  iap_source_range = "35.235.240.0/20"
}

# Ingress: SSH only, from Google's IAP range. There is no public IP and no
# operator-IP allow-list — IAP gates access via the operator's GCP IAM
# (roles/iap.tunnelResourceAccessor), so nothing here refreshes when they roam.
resource "google_compute_firewall" "ssh" {
  name    = "${var.name}-ssh"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = [local.iap_source_range]
  target_tags   = [var.name]
}

# Ingress: the externally-browsable ports — Grafana :3000 today (the relay vergil-vm
# provisions on the box's 0.0.0.0:3000 → the obs guest). Per-QM listener + mqweb ports
# are a deliberate follow-on (mq-resiliency-lab #345); add them here when they land.
# Wide open by design: these boxes are ephemeral with no real data and Grafana is
# anonymous/shareable, so the value (hand someone an IP) outweighs the exposure — if it
# breaks, rebuild. SSH is deliberately NOT here; it stays IAP-only above. (#260)
resource "google_compute_firewall" "browse" {
  name    = "${var.name}-browse"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["3000"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = [var.name]
}

resource "google_compute_instance" "vm" {
  name         = var.name
  machine_type = var.instance_type
  zone         = var.zone
  tags         = [var.name]
  labels       = var.labels

  # Ephemeral root/boot disk — dies with the instance. The persistent data disk is
  # attached separately below.
  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = var.boot_disk_gib
    }
  }

  # The persistent "laptop analog" volume, by self_link. Never auto-deleted.
  # device_name fixes the in-guest path (/dev/disk/by-id/google-vergil-data) the
  # cloud-init mount-volume.sh script formats-on-first-use and mounts at /vergil.
  attached_disk {
    source      = var.volume_id
    device_name = "vergil-data"
  }

  # Native-x86 nested KVM (the whole point — no TCG). The in-guest 70-nested-virt.sh
  # check fails the provision loudly if /dev/kvm never appears.
  advanced_machine_features {
    enable_nested_virtualization = var.nested
  }

  # Ephemeral public IP (access_config) so the box's browse ports (Grafana :3000 today;
  # per-QM listener + mqweb ports to follow) are reachable from a remote browser — the
  # point of running off-platform: show dashboards by IP, drive MQ Web/Explorer against
  # each QM, run multiple stacks. SSH still rides the IAP tunnel (gcloud compute ssh
  # --tunnel-through-iap); the module manages no SSH keypair. (#260)
  network_interface {
    network = "default"
    access_config {}
  }

  metadata = {
    user-data = local.user_data
  }
}
