# azurerm is a root-module provider here (the tooling runs `tofu` in this dir), so the
# required features{} block lives in the module. Subscription comes from ARM_SUBSCRIPTION_ID
# in the tofu environment (the tooling sets it); no credentials are committed.
provider "azurerm" {
  features {}
}

# Per-instance resource group (#242): every named instance owns its own RG holding all
# long-lived scaffolding. The gated destroy-volume verb deletes this RG and everything in it.
resource "azurerm_resource_group" "rg" {
  name     = "${var.name}-rg"
  location = var.region
  tags     = var.labels
}

resource "azurerm_virtual_network" "vnet" {
  name                = "${var.name}-vnet"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  address_space       = ["10.42.0.0/16"]
  tags                = var.labels
}

resource "azurerm_subnet" "subnet" {
  name                 = "${var.name}-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.42.0.0/24"]
}

# Subnet-attached NSG. The inbound-22 rule is long-lived (survives VM churn); its source
# is a non-routable placeholder that matches nothing until the SshTransport rewrites
# source_address_prefix to the operator's current /32 at session start (vergil-tooling).
resource "azurerm_network_security_group" "nsg" {
  name                = "${var.name}-nsg"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  tags                = var.labels

  security_rule {
    name                       = "ssh-operator"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "255.255.255.255/32" # placeholder: matches no real source
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "assoc" {
  subnet_id                 = azurerm_subnet.subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# The persistent "laptop analog" data disk. create_option = Empty; never auto-deleted.
# Azure disks cannot shrink in place, so a size_gib decrease must be a deliberate
# destroy-volume, not an in-place apply. zone = null => regional.
resource "azurerm_managed_disk" "data" {
  name                 = "${var.name}-data"
  resource_group_name  = azurerm_resource_group.rg.name
  location             = azurerm_resource_group.rg.location
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.size_gib
  zone                 = var.zone
  tags                 = var.labels
}
