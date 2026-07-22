locals {
  k3s_vms = {
    control_plane = {
      ipv4_address = var.vm_ipv4_addresses.control_plane
      memory_mb    = var.vm_memory_mb.control_plane
      name         = "k3s-control-plane-1"
      role         = "control-plane"
      vm_id        = var.vm_ids.control_plane
    }
    worker_1 = {
      ipv4_address = var.vm_ipv4_addresses.worker_1
      memory_mb    = var.vm_memory_mb.worker
      name         = "k3s-worker-1"
      role         = "worker"
      vm_id        = var.vm_ids.worker_1
    }
    worker_2 = {
      ipv4_address = var.vm_ipv4_addresses.worker_2
      memory_mb    = var.vm_memory_mb.worker
      name         = "k3s-worker-2"
      role         = "worker"
      vm_id        = var.vm_ids.worker_2
    }
  }
}

resource "proxmox_virtual_environment_vm" "k3s" {
  for_each                             = local.k3s_vms
  delete_unreferenced_disks_on_destroy = false
  vm_id                                = each.value.vm_id
  name                                 = each.value.name
  description                          = "Nœud ${each.value.role} du cluster k3s — géré par Terraform"
  node_name                            = var.proxmox_node_name
  scsi_hardware                        = "virtio-scsi-single"
  tags                                 = ["k3s", each.value.role, "terraform"]

  on_boot = true
  started = true

  clone {
    vm_id        = var.template_vm_id
    node_name    = var.proxmox_node_name
    datastore_id = var.proxmox_datastore_id
    full         = true
  }

  disk {
    datastore_id = var.proxmox_datastore_id
    interface    = "scsi0"
    size         = 20            # ⚠ mettre la taille réelle de scsi0 (qm config)
  }

  dynamic "disk" {
    for_each = each.key == "control_plane" ? [1] : []
    content {
      datastore_id      = var.proxmox_datastore_id
      path_in_datastore = "9900/vm-9900-disk-0.raw" # volume possédé hors VM
      interface         = "scsi1"
      size              = 100
    }
  }

  agent {
    enabled = true
  }

  cpu {
    cores = var.vm_cpu_cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory_mb
  }

  serial_device {
    device = "socket"
  }

  vga {
    type = "serial0"
  }

  network_device {
    bridge   = var.proxmox_network_bridge
    firewall = false
    model    = "virtio"
  }

  initialization {
    datastore_id      = var.proxmox_datastore_id
    interface         = "ide0"
    user_data_file_id = proxmox_virtual_environment_file.cloud_init[each.key].id

    user_account {
      username = var.vm_username
      password = var.vm_password
      keys = [
        trimspace(file(pathexpand(var.ssh_public_key_path))),
      ]
    }

    dns {
      servers = var.proxmox_dns_servers
    }

    ip_config {
      ipv4 {
        address = each.value.ipv4_address
        gateway = var.proxmox_network_gateway
      }
    }
  }
}
