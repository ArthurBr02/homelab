output "k3s_vms" {
  description = "Identité et adresses réseau des trois VMs k3s."
  value = {
    for key, vm in proxmox_virtual_environment_vm.k3s : key => {
      id             = vm.vm_id
      name           = vm.name
      ipv4_addresses = vm.ipv4_addresses
    }
  }
}
