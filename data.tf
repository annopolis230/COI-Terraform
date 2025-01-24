data "vsphere_datacenter" "datacenter" {
        name = "VxRail-Datacenter"
}

data "vsphere_compute_cluster" "cluster" {
        name = "VxRail-Cluster"
        datacenter_id = data.vsphere_datacenter.datacenter.id
}

data "vsphere_datastore" "datastore" {
        name = "VxRail-VSAN-Datastore"
        datacenter_id = data.vsphere_datacenter.datacenter.id
}

data "vsphere_network" "dhcp_network" {
        name = "COI_VMware_DHCP (VLAN 43)"
        datacenter_id = data.vsphere_datacenter.datacenter.id
}

data "vsphere_network" "static4_network" {
        name = "COI_VMware_Static_4 (VLAN 944)"
        datacenter_id = data.vsphere_datacenter.datacenter.id
}

data "vsphere_virtual_machine" "template" {
        name = "Blank_Ubuntu20_WithSSH"
        datacenter_id = data.vsphere_datacenter.datacenter.id
}