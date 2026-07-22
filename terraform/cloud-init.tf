locals {
  k3s_server_address = split("/", var.vm_ipv4_addresses.control_plane)[0]

  k3s_bootstrap = {
    control_plane = {
      install_exec = "server"
      config       = "cluster-init: true"
    }
    worker_1 = {
      install_exec = "agent"
      config       = "server: https://${local.k3s_server_address}:6443"
    }
    worker_2 = {
      install_exec = "agent"
      config       = "server: https://${local.k3s_server_address}:6443"
    }
  }
}

resource "local_sensitive_file" "cloud_init" {
  for_each = local.k3s_vms

  content = templatefile("${path.module}/cloud-init/k3s.yaml.tftpl", {
    hostname       = each.value.name
    install_exec   = local.k3s_bootstrap[each.key].install_exec
    k3s_config     = local.k3s_bootstrap[each.key].config
    k3s_token      = var.k3s_token
    ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
    username       = var.vm_username
    vm_password    = var.vm_password
  })

  filename        = "${path.module}/${each.value.name}-cloud-init.generated.yaml"
  file_permission = "0600"
}

resource "proxmox_virtual_environment_file" "cloud_init" {
  for_each = local.k3s_vms

  content_type = "snippets"
  datastore_id = var.proxmox_datastore_id
  node_name    = var.proxmox_node_name
  upload_mode  = "sftp"

  source_file {
    path      = local_sensitive_file.cloud_init[each.key].filename
    file_name = "${each.value.name}-cloud-init.yaml"
  }

  # bpg repère le fichier par son nom, pas par le hash du contenu : sans ça, une
  # modification du template ne ré-uploade pas le snippet. Forcer le remplacement
  # dès que le fichier local généré change.
  lifecycle {
    replace_triggered_by = [local_sensitive_file.cloud_init[each.key].id]
  }
}
