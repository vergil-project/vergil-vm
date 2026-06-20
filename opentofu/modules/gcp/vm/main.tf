locals {
  # Indent the multi-line provision.env body to sit under cloud-init's `content: |`
  # (6-space content indent), then splice it in via replace(). We deliberately do NOT
  # use templatefile(): the generated cloud-init.yaml inlines provision scripts that
  # contain shell ${...}, which templatefile would try to interpret as Terraform.
  provision_env_block = replace(var.provision_env, "\n", "\n      ")
  user_data           = replace(file("${path.module}/cloud-init.yaml"), "@@PROVISION_ENV@@", local.provision_env_block)
}

# Ingress: SSH only, from the create-initiator's origin address(es). The variable
# validation already forbids an empty list and 0.0.0.0/0.
resource "google_compute_firewall" "ssh" {
  name    = "${var.name}-ssh"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = var.ssh_source_ranges
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

  network_interface {
    network = "default"
    access_config {} # ephemeral public IP for SSH
  }

  metadata = {
    ssh-keys  = "${var.ssh_user}:${var.ssh_public_key}"
    user-data = local.user_data
  }
}
