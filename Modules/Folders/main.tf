resource "vsphere_folder" "member_folder" {
        for_each = toset(var.student_list)
        path = "${var.folder}/${each.key}"
        type = "vm"
        datacenter_id = var.data["datacenter_id"]

        lifecycle {
                ignore_changes = all
                create_before_destroy = true
        }
}

output "folder_ids" {
    value = [for folder in vsphere_folder.member_folder : folder.path] 
}