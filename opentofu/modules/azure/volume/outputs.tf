output "volume_id" { value = azurerm_managed_disk.data.id }
output "zone" { value = var.zone == null ? "" : var.zone }
