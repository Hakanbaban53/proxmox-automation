output "template_vm_id" {
  description = "VMID of the golden template."
  value       = proxmox_virtual_environment_vm.ubuntu_template.vm_id
}

output "test_vm_id" {
  description = "VMID of the Phase 1 workload VM."
  value       = proxmox_virtual_environment_vm.test_vm.vm_id
}

output "test_vm_name" {
  description = "Name of the Phase 1 workload VM."
  value       = proxmox_virtual_environment_vm.test_vm.name
}

output "test_vm_ip" {
  description = "Static IPv4 address pushed to the VM via cloud-init."
  value       = var.vm_ip_address
}

output "ssh_command" {
  description = "Ready-to-run SSH command for the new VM."
  value       = "ssh ${var.vm_username}@${var.vm_ip_address}"
}
