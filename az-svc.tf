# We strongly recommend using the required_providers block to set the
# Azure Provider source and version being used
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.0.0"
    }
  }
}

# Configure the Microsoft Azure Provider
provider "azurerm" {
  skip_provider_registration = true # This is only required when the User, Service Principal, or Identity running Terraform lacks the permissions to register Azure Resource Providers.
  features {}
}

# Create a resource group
resource "azurerm_resource_group" "az-tf-rg" {
  name     = "tf-az"
  location = "East US"

  tags = {
    env = "dev"
  }
}

# VNET
resource "azurerm_virtual_network" "az-tf-vnet" {
  name                = "terraform-network"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.az-tf-rg.location
  resource_group_name = azurerm_resource_group.az-tf-rg.name
}

# SUBNET
resource "azurerm_subnet" "az-tf-sn" {
  name                 = "terraform-subnet"
  resource_group_name  = azurerm_resource_group.az-tf-rg.name
  virtual_network_name = azurerm_virtual_network.az-tf-vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

# PUBLIC IP
resource "azurerm_public_ip" "az-tf-pip" {
  name                = "tf-pub-ip"
  resource_group_name = azurerm_resource_group.az-tf-rg.name
  location            = azurerm_resource_group.az-tf-rg.location
  allocation_method   = "Static"

  tags = {
    env = "dev"
  }
}

# NIC
resource "azurerm_network_interface" "az-tf-nic" {
  name                = "terraform-nic"
  location            = azurerm_resource_group.az-tf-rg.location
  resource_group_name = azurerm_resource_group.az-tf-rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.az-tf-sn.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.az-tf-pip.id
  }
}

# VM
resource "azurerm_linux_virtual_machine" "az-tf-vm" {
  name                = "az-docker-vm"
  resource_group_name = azurerm_resource_group.az-tf-rg.name
  location            = azurerm_resource_group.az-tf-rg.location
  size                = "Standard_F2"
  admin_username      = "adminuser"
  custom_data         = filebase64("script.sh")
  network_interface_ids = [
    azurerm_network_interface.az-tf-nic.id,
  ]

  admin_ssh_key {
    username   = "adminuser"
    public_key = file("~/.ssh/id_rsa.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}

# Postgres DB Password
variable "administrator_password" {
  description = "Password for the administrator of the PostgreSQL server"
}


# Postgres DB
resource "azurerm_postgresql_flexible_server" "az-lms-tf-db" {
  name                   = "az-lms-tf-postgres-db"
  location               = azurerm_resource_group.az-tf-rg.location
  resource_group_name    = azurerm_resource_group.az-tf-rg.name
  sku_name               = "GP_Standard_D2ds_v4"
  version                = "13"
  storage_mb             = 32768
  administrator_login    = "admin_user"
  administrator_password = var.administrator_password
  zone                   = "2"
}

# Postgres Firewall Rule
resource "azurerm_postgresql_flexible_server_firewall_rule" "az-lms-tf-db-fw" {
  name             = "az-lms-db-firewall"
  server_id        = azurerm_postgresql_flexible_server.az-lms-tf-db.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "255.255.255.255"
}

# Azure Container Registry
resource "azurerm_container_registry" "az-lms-tf-acr" {
  name                = "azurelmsregistry"
  resource_group_name = azurerm_resource_group.az-tf-rg.name
  location            = azurerm_resource_group.az-tf-rg.location
  sku                 = "Standard"
  admin_enabled       = "true"
}

# Assign Role For ACR
resource "azurerm_role_assignment" "az-tf-acr-access" {
  principal_id         = "e8e9b779-01c6-4c96-bcfd-b2d9ade5822f" # User's Object ID
  role_definition_name = "Owner"
  scope                = azurerm_container_registry.az-lms-tf-acr.id
}

# Service Plan
resource "azurerm_service_plan" "az-lms-tf-svcp" {
  name                = "azlmstfbe"
  resource_group_name = azurerm_resource_group.az-tf-rg.name
  location            = azurerm_resource_group.az-tf-rg.location
  os_type             = "Linux"
  sku_name            = "S2"
}

# App Service
resource "azurerm_linux_web_app" "az-lms-tf-nodebe" {
  name                = "az-lms-tf-be-svc-7am"
  location            = azurerm_resource_group.az-tf-rg.location
  resource_group_name = azurerm_resource_group.az-tf-rg.name
  service_plan_id     = azurerm_service_plan.az-lms-tf-svcp.id

  site_config {
    application_stack {
      docker_image     = "azurelmsregistry.azurecr.io/lms-be"
      docker_image_tag = "latest"
    }
  }
  app_settings = {

    "DOCKER_REGISTRY_SERVER_URL"      = "azurelmsregistry.azurecr.io"
    "DOCKER_REGISTRY_SERVER_USERNAME" = "azurelmsregistry"
    "DOCKER_REGISTRY_SERVER_PASSWORD" = "BfdTEr9Rc1f9MAjP1JUZfXAehDU/IAL5SvlFjOUpjL+ACRDKwLtx"
    "PORT"                            = "3000"
    "MODE"                            = "production"
    "DB_USER"                         = "admin_user"
    "DB_HOST"                         = "az-lms-tf-postgres-db.postgres.database.azure.com"
    "DB_PORT"                         = "5432"
    "DB_NAME"                         = "postgres"
    "DB_PASSWORD"                     = "admin123"

    "DATABASE_URL" = "postgres://${var.DB_USER}:${var.DB_PASSWORD}@${var.DB_HOST}:${var.DB_PORT}/${var.DB_NAME}"
  }

}
