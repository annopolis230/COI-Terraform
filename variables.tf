variable "vsphere_username" {
    ephemeral = true
}
variable "vsphere_password" {
    ephemeral = true
}
variable "student_list" {
    type = list(string)
}
variable "professor_list" {
    type = list(string)
}
variable "folder" {}