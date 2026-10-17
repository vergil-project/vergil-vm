# The IAP target. SSH never uses the ephemeral external IP — the tunnel addresses the
# box by instance name within its zone (the consumer already holds the zone it passed
# in), i.e. gcloud compute ssh "${ssh_user}@${host}" --zone <zone>
# --tunnel-through-iap. The external IP is looked up at read time (vrg-vm list), not
# exported here, so the provider-agnostic interface stays unchanged.
output "host" { value = google_compute_instance.vm.name }
output "ssh_user" { value = var.ssh_user }
