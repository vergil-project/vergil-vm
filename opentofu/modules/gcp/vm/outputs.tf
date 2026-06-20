output "host" { value = google_compute_instance.vm.network_interface[0].access_config[0].nat_ip }
output "ssh_user" { value = var.ssh_user }
