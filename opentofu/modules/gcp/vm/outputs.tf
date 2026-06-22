# The IAP target. With no public IP there is no NAT address to hand back — the tunnel
# addresses the box by instance name within its zone (the consumer already holds the
# zone it passed in), i.e. gcloud compute ssh "${ssh_user}@${host}" --zone <zone>
# --tunnel-through-iap.
output "host" { value = google_compute_instance.vm.name }
output "ssh_user" { value = var.ssh_user }
