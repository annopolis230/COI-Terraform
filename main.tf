module "snapshots" {
        source = "./Modules/Snapshots"
        student_list = var.student_list
        professor_list = var.professor_list
        folder = var.folder
        vm_ids = module.virtual_machines.vm_ids
        data = local.shared_data

        depends_on = [module.virtual_machines.vms_complete]
}

module "virtual_machines" {
        source = "./Modules/VirtualMachines"
        student_list = var.student_list
        professor_list = var.professor_list
        data = local.shared_data
        folder_ids = module.folders.folder_ids
}

module "folders" {
        source = "./Modules/Folders"
        student_list = var.student_list
        professor_list = var.professor_list
        folder = var.folder
        data = local.shared_data
}

locals {
        shared_data = {
                resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
                datastore_id = data.vsphere_datastore.datastore.id
                datacenter_id = data.vsphere_datacenter.datacenter.id
        }
}

output "vm_ids" {
        value = module.virtual_machines.vm_ids
}

output "folder_ids" {
        value = module.folders.folder_ids
}