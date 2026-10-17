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

  # The browse ports are the host-side ports of the repo profile's [vm] port_forwards
  # — the same declaration 80-port-forwards.sh turns into 0.0.0.0:<port> relays, so a
  # repo controls its exposure in one place (#322). They arrive inside provision_env,
  # which vergil-tooling renders as one shell-quoted line per key:
  #   PORT_FORWARDS='<port>|<host:port>;<port>|<host:port>'   (or '' when none)
  # The instance preconditions below check the match; an absent or doubled line fails
  # the plan rather than silently opening nothing.
  port_forwards_match = regexall("(?m)^PORT_FORWARDS='?([^'\\n]*)'?$", var.provision_env)
  port_forwards       = length(local.port_forwards_match) == 1 ? compact(split(";", local.port_forwards_match[0][0])) : []
  browse_ports_raw    = distinct([for f in local.port_forwards : split("|", f)[0]])
  # Canonical decimal form ("09443" -> "9443"); try() keeps a non-numeric port (which
  # a precondition rejects with a clear message) from aborting evaluation first.
  browse_ports = distinct([for p in local.browse_ports_raw : try(tostring(tonumber(p)), p)])
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

# Ingress: the externally-browsable ports — exactly the host ports the profile's
# port_forwards declares (local.browse_ports), each a relay vergil-vm provisions on the
# box's 0.0.0.0:<port>. Undeclared ports stay closed. With no port_forwards the rule is
# not created at all: a GCE allow block with an empty `ports` list admits EVERY port of
# the protocol, so an empty list must never reach it. Wide open by design: these boxes
# are ephemeral with no real data and the forwarded UIs are meant to be shared, so the
# value (hand someone an IP) outweighs the exposure — if it breaks, rebuild. SSH is
# deliberately NOT here; it stays IAP-only above, and a forward of host port 22 fails
# the plan (see the instance preconditions). (#260, #322)
resource "google_compute_firewall" "browse" {
  count   = length(local.browse_ports) > 0 ? 1 : 0
  name    = "${var.name}-browse"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = local.browse_ports
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = [var.name]
}

# The rule was a singleton before it became conditional (#322): carry existing state
# across rather than destroying and recreating the same-named rule.
moved {
  from = google_compute_firewall.browse
  to   = google_compute_firewall.browse[0]
}

resource "google_compute_instance" "vm" {
  name         = var.name
  machine_type = var.instance_type
  zone         = var.zone
  tags         = [var.name]
  labels       = var.labels

  # Ephemeral root/boot disk — dies with the instance. The persistent data disk is
  # attached separately below. A null boot_disk_type omits `type`, so GCE applies the
  # machine series' default disk type; any change to it replaces the instance.
  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = var.boot_disk_gib
      type  = var.boot_disk_type
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

  # Ephemeral public IP (access_config) so the box's browse ports (the port_forwards
  # host ports the browse rule admits) are reachable from a remote browser — the point
  # of running off-platform: show dashboards by IP, drive MQ Web/Explorer against each
  # QM, run multiple stacks. SSH still rides the IAP tunnel (gcloud compute ssh
  # --tunnel-through-iap); the module manages no SSH keypair. (#260)
  network_interface {
    network = "default"
    access_config {}
  }

  metadata = {
    user-data = local.user_data
  }

  # The browse-port derivation (locals above) must see a well-formed PORT_FORWARDS.
  # These fail the plan before anything is created — never open a guessed port set.
  lifecycle {
    precondition {
      condition     = length(local.port_forwards_match) == 1
      error_message = "provision_env must define PORT_FORWARDS exactly once (found ${length(local.port_forwards_match)}); the browse firewall is derived from it."
    }
    precondition {
      condition     = alltrue([for p in local.browse_ports_raw : can(regex("^[0-9]+$", p)) && try(tonumber(p) >= 1 && tonumber(p) <= 65535, false)])
      error_message = "every port_forwards host port must be an integer 1-65535; got ${jsonencode(local.browse_ports_raw)}."
    }
    precondition {
      condition     = !contains(local.browse_ports, "22")
      error_message = "port_forwards must not forward host port 22: SSH stays IAP-only and the browse firewall never opens it."
    }
  }
}
