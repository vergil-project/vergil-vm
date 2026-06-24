provider "azurerm" {
  features {}
}

locals {
  # Parse subscription + resource group out of volume_id. split("/", id) yields
  # ["", "subscriptions", <sub>, "resourceGroups", <rg>, "providers", ...]; the
  # subscription is index 2 and the resource group index 4. This is the Azure analog of
  # GCP passing the disk self_link — the resource-group dimension needs no interface key.
  id_parts       = split("/", var.volume_id)
  resource_group = local.id_parts[4]

  # Coarse nested-virt-capable family guard. The Dv3+/Ev3+/Fsv2 families all start with
  # one of these prefixes; the in-guest 70-nested-virt.sh /dev/kvm check is the precise
  # backstop. (Cross-variable checks aren't allowed in variable{} validation on OpenTofu
  # 1.8, so this is enforced as a resource precondition below.)
  nested_capable_prefixes = ["Standard_D", "Standard_E", "Standard_F"]

  # Splice the provision.env body into the generated cloud-init, then base64 it for
  # custom_data. replace() (not templatefile) because the inlined provision scripts
  # contain shell ${...} that templatefile would try to interpret as Terraform.
  provision_env_block = replace(var.provision_env, "\n", "\n      ")
  user_data           = replace(file("${path.module}/cloud-init.yaml"), "@@PROVISION_ENV@@", local.provision_env_block)
}

# Long-lived networking + disk created by the volume module, looked up by convention
# within the parsed resource group. The disk's location pins every resource's region,
# so the vm module needs no region variable.
data "azurerm_managed_disk" "data" {
  name                = "${var.name}-data"
  resource_group_name = local.resource_group
}

data "azurerm_subnet" "subnet" {
  name                 = "${var.name}-subnet"
  virtual_network_name = "${var.name}-vnet"
  resource_group_name  = local.resource_group
}

resource "azurerm_public_ip" "pip" {
  name                = "${var.name}-pip"
  resource_group_name = local.resource_group
  location            = data.azurerm_managed_disk.data.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.labels
}

resource "azurerm_network_interface" "nic" {
  name                = "${var.name}-nic"
  resource_group_name = local.resource_group
  location            = data.azurerm_managed_disk.data.location
  tags                = var.labels

  ip_configuration {
    name                          = "primary"
    subnet_id                     = data.azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip.id
  }
}

resource "azurerm_linux_virtual_machine" "vm" {
  name                  = var.name
  resource_group_name   = local.resource_group
  location              = data.azurerm_managed_disk.data.location
  size                  = var.instance_type
  admin_username        = var.ssh_user
  network_interface_ids = [azurerm_network_interface.nic.id]
  zone                  = var.zone == "" ? null : var.zone
  tags                  = var.labels

  # NESTED VIRT IS LOAD-BEARING: do NOT set secure_boot_enabled / vtpm_enabled. Leaving
  # them unset keeps the VM at the Standard security type. Trusted Launch (the portal
  # default for many sizes) is INCOMPATIBLE with nested virtualization — the in-guest
  # /dev/kvm would never appear and 70-nested-virt.sh would fail the provision.

  admin_ssh_key {
    username   = var.ssh_user
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.boot_disk_gib
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # cloud-init user-data; Azure consumes it base64-encoded via custom_data.
  custom_data = base64encode(local.user_data)

  disable_password_authentication = true

  lifecycle {
    precondition {
      condition     = !var.nested || anytrue([for p in local.nested_capable_prefixes : startswith(var.instance_type, p)])
      error_message = "nested=true but instance_type ${var.instance_type} is not a nested-virt-capable family (expected Dv3+/Ev3+/Fsv2, e.g. Standard_D16s_v5)."
    }
  }
}

# Attach the persistent data disk at LUN 0 -> in-guest /dev/disk/azure/scsi1/lun0
# (the path mount-volume.sh formats-on-first-use and mounts at /vergil).
resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  managed_disk_id    = data.azurerm_managed_disk.data.id
  virtual_machine_id = azurerm_linux_virtual_machine.vm.id
  lun                = 0
  caching            = "ReadWrite"
}
