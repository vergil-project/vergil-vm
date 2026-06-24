# The routable public IP (NSG-locked to the operator's current /32 by the tooling).
output "host" { value = azurerm_public_ip.pip.ip_address }
output "ssh_user" { value = var.ssh_user }
