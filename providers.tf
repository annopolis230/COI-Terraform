terraform {
        backend "azurerm" {
                resource_group_name = "terraform-config-data"
                storage_account_name = "terraformconfigdata"
                container_name = "tfstate"
                key = "terraform.tfstate"
        }
        required_providers {
                vsphere = {
                        source = "hashicorp/vsphere"
                        version = "2.0.2"
                }
        }
}

// This ensures that these local variables implicitly become ephemeral, i.e. only available during the current terraform run
locals {
        vsphere_username = var.vsphere_username
        vsphere_password = var.vsphere_password
}

provider "vsphere" {
    user = local.vsphere_username
    password = local.vsphere_password
    vsphere_server = "coivcenter1.hh.nku.edu"
    allow_unverified_ssl = true
}