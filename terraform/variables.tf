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

variable "proxmox_network_gateway" {
  description = "Passerelle IPv4 utilisée par les VMs."
  type        = string
  default     = "192.168.1.1"
}

variable "proxmox_dns_servers" {
  description = "Serveurs DNS utilisés par les VMs."
  type        = list(string)
  default     = ["192.168.1.1"]
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

variable "vm_ipv4_addresses" {
  description = "Adresses IPv4 statiques des trois VMs, au format CIDR."
  type = object({
    control_plane = string
    worker_1      = string
    worker_2      = string
  })
  default = {
    control_plane = "192.168.1.100/24"
    worker_1      = "192.168.1.101/24"
    worker_2      = "192.168.1.102/24"
  }

  validation {
    condition = length(distinct([
      var.vm_ipv4_addresses.control_plane,
      var.vm_ipv4_addresses.worker_1,
      var.vm_ipv4_addresses.worker_2,
    ])) == 3
    error_message = "Les trois adresses IPv4 doivent être différentes."
  }
}

variable "vm_username" {
  description = "Utilisateur créé par Cloud-Init dans chaque VM."
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key_path" {
  description = "Chemin local de la clé publique autorisée à se connecter aux VMs."
  type        = string
  default     = "~/.ssh/id_rsa.pub"

  validation {
    condition     = fileexists(pathexpand(var.ssh_public_key_path))
    error_message = "Le fichier défini par ssh_public_key_path doit exister."
  }
}

variable "vm_password" {
  description = "Mot de passe facultatif pour se connecter depuis la console Proxmox."
  type        = string
  default     = null
  sensitive   = true
  nullable    = true
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

variable "k3s_token" {
  description = "Jeton partagé par les nœuds du cluster k3s."
  type        = string
  sensitive   = true
}
