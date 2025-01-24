resource "vsphere_virtual_machine_snapshot" "day1" {
        for_each = toset(var.vm_ids)
        virtual_machine_uuid = each.key
        snapshot_name = "day1"
        description = "Snapshot created immediately after provisioning. It is recommended not to delete this snapshot."
        memory = false
        quiesce = false

        lifecycle {
                ignore_changes = all
        }
}