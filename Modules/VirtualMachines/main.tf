data "vsphere_network" "dhcp_network" {
        name = "COI_VMware_DHCP (VLAN 43)"
        datacenter_id = var.data["datacenter_id"]
}

data "vsphere_network" "static4_network" {
        name = "COI_VMware_Static_4 (VLAN 944)"
        datacenter_id = var.data["datacenter_id"]
}

data "vsphere_virtual_machine" "template" {
        name = "Blank_Ubuntu20_WithSSH"
        datacenter_id = var.data["datacenter_id"]
}

resource "vsphere_virtual_machine" "vm" {
        for_each = toset(var.folder_ids)
        resource_pool_id = var.data["resource_pool_id"]
        datastore_id = var.data["datastore_id"]
        guest_id = data.vsphere_virtual_machine.template.guest_id
        num_cpus = data.vsphere_virtual_machine.template.num_cpus
        memory = data.vsphere_virtual_machine.template.memory

        name = "TF-test-${each.key}"
        folder = each.value

        network_interface {
                network_id = data.vsphere_network.dhcp_network.id
                adapter_type = "vmxnet3"
        }

        disk {
                label = "disk0"
                size = data.vsphere_virtual_machine.template.disks.0.size
                // assumes thin provisioned
        }

        clone {
                template_uuid = data.vsphere_virtual_machine.template.id
                customize {
                        timeout = -1 // disable the network waiter. this ensures that network customization (i.e. default gateway and ip assignment) will eventually finish.
                        linux_options {
                                host_name = "terraform-vm"
                                domain = "local"
                        }
                        network_interface {}
                }
        }

        lifecycle {
                ignore_changes = all
        }
}

resource "null_resource" "vms_complete" {
    triggers = {
        vm_ids = join(",", [for vm in vsphere_virtual_machine.vm : vm.id])
    }
}

output "vm_ids" {
    value = [for vm in vsphere_virtual_machine.vm : vm.id]
}