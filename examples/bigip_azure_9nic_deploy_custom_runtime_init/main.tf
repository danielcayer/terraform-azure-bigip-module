provider "azurerm" {
  //  version = "~>2.0"
  features {}
}

#
# Create a random id
#
resource "random_id" "id" {
  byte_length = 2
}

#
# Create a resource group
#
resource "azurerm_resource_group" "rg" {
  name     = format("%s-rg-%s", var.prefix, random_id.id.hex)
  location = var.location
}

resource "azurerm_ssh_public_key" "f5_key" {
  name                = format("%s-pubkey-%s", var.prefix, random_id.id.hex)
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  public_key          = file("~/.ssh/id_rsa_azure.pub")
}

data "template_file" "user_data_vm0" {
  template = file("custom_onboard_big.tmpl")
  vars = {
    INIT_URL                   = var.INIT_URL
    DO_URL                     = var.DO_URL
    AS3_URL                    = var.AS3_URL
    TS_URL                     = var.TS_URL
    CFE_URL                    = var.CFE_URL
    FAST_URL                   = var.FAST_URL,
    DO_VER                     = format("v%s", split("-", split("/", var.DO_URL)[length(split("/", var.DO_URL)) - 1])[3])
    AS3_VER                    = format("v%s", split("-", split("/", var.AS3_URL)[length(split("/", var.AS3_URL)) - 1])[2])
    TS_VER                     = format("v%s", split("-", split("/", var.TS_URL)[length(split("/", var.TS_URL)) - 1])[2])
    CFE_VER                    = format("v%s", split("-", split("/", var.CFE_URL)[length(split("/", var.CFE_URL)) - 1])[3])
    FAST_VER                   = format("v%s", split("-", split("/", var.FAST_URL)[length(split("/", var.FAST_URL)) - 1])[3])
    az_keyvault_authentication = false
    vault_url                  = ""
    secret_id                  = ""
    bigip_username             = var.f5_username
    ssh_keypair                = fileexists("~/.ssh/id_rsa_azure.pub") ? file("~/.ssh/id_rsa_azure.pub") : ""
    bigip_password             = var.f5_password
  }
}

#
#Create N-nic bigip
#
module "bigip" {
  count                       = var.instance_count
  source                      = "../../"
  prefix                      = format("%s-8nic", var.prefix)
  resource_group_name         = azurerm_resource_group.rg.name
  f5_ssh_publickey            = azurerm_ssh_public_key.f5_key.public_key
  mgmt_subnet_ids             = [{ "subnet_id" = data.azurerm_subnet.mgmt.id, "public_ip" = true, "private_ip_primary" = "" }]
  mgmt_securitygroup_ids      = [module.mgmt-network-security-group.network_security_group_id]
  external_subnet_ids         = [{ "subnet_id" = data.azurerm_subnet.external-public.id, "public_ip" = true, "private_ip_primary" = "", "private_ip_secondary" = "" }]
  external_securitygroup_ids  = [module.external-network-security-group-public.network_security_group_id]
  internal_subnet_ids         = [{ "subnet_id" = data.azurerm_subnet.internal.id, "public_ip" = false, "private_ip_primary" = "" }, { "subnet_id" = data.azurerm_subnet.ftd-in.id, "public_ip" = false, "private_ip_primary" = "" }, { "subnet_id" = data.azurerm_subnet.ftd-out.id, "public_ip" = false, "private_ip_primary" = "" }, { "subnet_id" = data.azurerm_subnet.wsa-in.id, "public_ip" = false, "private_ip_primary" = "" }, { "subnet_id" = data.azurerm_subnet.wsa-out.id, "public_ip" = false, "private_ip_primary" = "" }, { "subnet_id" = data.azurerm_subnet.inspection-in.id, "public_ip" = false, "private_ip_primary" = "" }]
  internal_securitygroup_ids  = [module.internal-network-security-group.network_security_group_id, module.internal-network-security-group.network_security_group_id, module.internal-network-security-group.network_security_group_id, module.internal-network-security-group.network_security_group_id, module.internal-network-security-group.network_security_group_id, module.internal-network-security-group.network_security_group_id]
  availability_zone           = var.availability_zone
  availabilityZones_public_ip = var.availabilityZones_public_ip
  f5_username                 = var.f5_username
  f5_password                 = var.f5_password
  f5_instance_type            = var.f5_instance_type
  custom_user_data            = data.template_file.user_data_vm0.rendered
}

resource "local_file" "revoke_bigip_license_script_file" {
  #overwrite script file if already exists (touch or create if it doesn't already exist)
  content  = ""
  filename = "${path.root}/revoke_bigip_license_script.sh"
}

resource "null_resource" "bash_script_to_revoke_eval_keys_upon_destroy" {
  #the resulting script revokes bigip VE license prior to destroy
  provisioner "local-exec" {
    command = "echo \"ssh -i ~/.ssh/id_rsa_azure -tt ${var.f5_username}@${module.bigip[0].mgmtPublicIP} 'echo y | tmsh -q revoke sys license 2>/dev/null'\" >> ${path.root}/revoke_bigip_license_script.sh"
    #command = "echo \"ssh -i ~/.ssh/id_rsa_azure -tt ${var.f5_username}@${module.bigip.azurerm_public_ip.mgmt_public_ip[0].ip_address} 'echo y | tmsh -q revoke sys license 2>/dev/null'\" >> ${path.root}/revoke_bigip_license_script.sh"
  }
}

resource "null_resource" "revoke_bigip_licenses" {
  provisioner "local-exec" {
    # Recycle/revoke eval keys prior to destroying the bigip (useful for demo purposes)
    #ssh -i ~/.ssh/id_rsa_azure -tt bigipuser@20.116.0.142 'echo y | tmsh -q revoke sys license 2>/dev/null'
    command    = "${path.root}/revoke_bigip_license_script.sh"
    on_failure = continue
    when       = destroy
  }
  depends_on = [module.bigip, azurerm_network_security_rule.mgmt_allow_ssh]
}

#
# Create the Network Module to associate with BIGIP
#

module "network" {
  source              = "Azure/vnet/azurerm"
  vnet_name           = format("%s-vnet-%s", var.prefix, random_id.id.hex)
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = [var.cidr]
  subnet_prefixes     = [cidrsubnet(var.cidr, 8, 1), cidrsubnet(var.cidr, 8, 2), cidrsubnet(var.cidr, 8, 3), cidrsubnet(var.cidr, 8, 4), cidrsubnet(var.cidr, 8, 5), cidrsubnet(var.cidr, 8, 6), cidrsubnet(var.cidr, 8, 7), cidrsubnet(var.cidr, 8, 8), cidrsubnet(var.cidr, 8, 9), cidrsubnet(var.cidr, 8, 10)]
  subnet_names        = ["mgmt-subnet", "external-public-subnet", "external-public-subnet2", "internal-subnet", "ftd-in-subnet", "ftd-out-subnet", "wsa-in-subnet", "wsa-out-subnet", "inspection-in-subnet", "inspection-out-subnet"]

  tags = {
    environment = "dev"
    costcenter  = "it"
  }
}

data "azurerm_subnet" "mgmt" {
  name                 = "mgmt-subnet"
  virtual_network_name = module.network.vnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  depends_on           = [module.network]
}

data "azurerm_subnet" "external-public" {
  name                 = "external-public-subnet"
  virtual_network_name = module.network.vnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  depends_on           = [module.network]
}

data "azurerm_subnet" "external-public2" {
  name                 = "external-public-subnet2"
  virtual_network_name = module.network.vnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  depends_on           = [module.network]
}

data "azurerm_subnet" "internal" {
  name                 = "internal-subnet"
  virtual_network_name = module.network.vnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  depends_on           = [module.network]
}

data "azurerm_subnet" "ftd-in" {
  name                 = "ftd-in-subnet"
  virtual_network_name = module.network.vnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  depends_on           = [module.network]
}

data "azurerm_subnet" "ftd-out" {
  name                 = "ftd-out-subnet"
  virtual_network_name = module.network.vnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  depends_on           = [module.network]
}

data "azurerm_subnet" "wsa-in" {
  name                 = "wsa-in-subnet"
  virtual_network_name = module.network.vnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  depends_on           = [module.network]
}

data "azurerm_subnet" "wsa-out" {
  name                 = "wsa-out-subnet"
  virtual_network_name = module.network.vnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  depends_on           = [module.network]
}

data "azurerm_subnet" "inspection-in" {
  name                 = "inspection-in-subnet"
  virtual_network_name = module.network.vnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  depends_on           = [module.network]
}

data "azurerm_subnet" "inspection-out" {
  name                 = "inspection-out-subnet"
  virtual_network_name = module.network.vnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  depends_on           = [module.network]
}

#
# Create the Network Security group Module to associate with BIGIP-Mgmt-Nic
#
module "mgmt-network-security-group" {
  source              = "Azure/network-security-group/azurerm"
  resource_group_name = azurerm_resource_group.rg.name
  security_group_name = format("%s-mgmt-nsg-%s", var.prefix, random_id.id.hex)
  tags = {
    environment = "dev"
    costcenter  = "terraform"
  }
}

#
# Create the Network Security group Module to associate with BIGIP-External-Nic
#
module "external-network-security-group-public" {
  source              = "Azure/network-security-group/azurerm"
  resource_group_name = azurerm_resource_group.rg.name
  security_group_name = format("%s-external-public-nsg-%s", var.prefix, random_id.id.hex)
  tags = {
    environment = "dev"
    costcenter  = "terraform"
  }
}

resource "azurerm_network_security_rule" "mgmt_allow_https" {
  name                        = "Allow_Https"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  destination_address_prefix  = "*"
  source_address_prefixes     = var.AllowedIPs
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = format("%s-mgmt-nsg-%s", var.prefix, random_id.id.hex)
  depends_on                  = [module.mgmt-network-security-group]
}
resource "azurerm_network_security_rule" "mgmt_allow_ssh" {
  name                        = "Allow_ssh"
  priority                    = 202
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  destination_address_prefix  = "*"
  source_address_prefixes     = var.AllowedIPs
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = format("%s-mgmt-nsg-%s", var.prefix, random_id.id.hex)
  depends_on                  = [module.mgmt-network-security-group]
}

resource "azurerm_network_security_rule" "external_allow_https" {
  name                        = "Allow_Https"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  destination_address_prefix  = "*"
  source_address_prefixes     = var.AllowedIPs
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = format("%s-external-public-nsg-%s", var.prefix, random_id.id.hex)
  depends_on                  = [module.external-network-security-group-public]
}
resource "azurerm_network_security_rule" "external_allow_ssh" {
  name                        = "Allow_ssh"
  priority                    = 202
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  destination_address_prefix  = "*"
  source_address_prefixes     = var.AllowedIPs
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = format("%s-external-public-nsg-%s", var.prefix, random_id.id.hex)
  depends_on                  = [module.external-network-security-group-public]
}

#
# Create the Network Security group Module to associate with BIGIP-Internal-Nic
#
module "internal-network-security-group" {
  source                = "Azure/network-security-group/azurerm"
  resource_group_name   = azurerm_resource_group.rg.name
  security_group_name   = format("%s-internal-nsg-%s", var.prefix, random_id.id.hex)
  source_address_prefix = ["10.0.3.0/24"]
  tags = {
    environment = "dev"
    costcenter  = "terraform"
  }
}
