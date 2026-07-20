variable "proxmox_endpoint" {
  description = "URL de l'API Proxmox."
  type        = string
}

variable "proxmox_api_token_id" {
  description = "Identifiant du jeton API Proxmox, par exemple terraform@pve!homelab."
  type        = string
  sensitive   = true
}

variable "proxmox_api_token_secret" {
  description = "Secret du jeton API Proxmox."
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Autorise le certificat TLS autosigné de Proxmox."
  type        = bool
  default     = true
}

variable "proxmox_node_name" {
  description = "Nœud Proxmox qui héberge les VMs."
  type        = string
  default     = "px1"
}

variable "proxmox_datastore_id" {
  description = "Stockage utilisé pour les disques clonés et Cloud-Init."
  type        = string
  default     = "media-storage"
}

variable "proxmox_network_bridge" {
  description = "Bridge réseau utilisé par les VMs."
  type        = string
  default     = "vmbr0"
}

variable "template_vm_id" {
  description = "ID du template Ubuntu 24.04 Cloud-Init."
  type        = number
  default     = 9000
}

variable "vm_cpu_cores" {
  description = "Nombre de vCPU attribués à chaque VM."
  type        = number
  default     = 2

  validation {
    condition     = var.vm_cpu_cores >= 1
    error_message = "Chaque VM doit avoir au moins un vCPU."
  }
}

variable "vm_memory_mb" {
  description = "Mémoire dédiée à la cheffe et à chaque ouvrière, en Mo."
  type = object({
    control_plane = number
    worker        = number
  })
  default = {
    control_plane = 4096
    worker        = 4096
  }

  validation {
    condition = alltrue([
      var.vm_memory_mb.control_plane >= 2048,
      var.vm_memory_mb.worker >= 2048,
    ])
    error_message = "Chaque nœud k3s doit disposer d'au moins 2 048 Mo de RAM."
  }
}

variable "vm_ids" {
  description = "IDs Proxmox fixes des trois VMs k3s."
  type = object({
    control_plane = number
    worker_1      = number
    worker_2      = number
  })
  default = {
    control_plane = 9001
    worker_1      = 9002
    worker_2      = 9003
  }

  validation {
    condition = length(distinct([
      var.vm_ids.control_plane,
      var.vm_ids.worker_1,
      var.vm_ids.worker_2,
    ])) == 3
    error_message = "Les trois IDs de VM doivent être différents."
  }
}
