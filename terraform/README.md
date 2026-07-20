# Infrastructure Proxmox du cluster k3s

Cette configuration clone le template Ubuntu Cloud-Init `9000` pour créer :

| ID | Nom | Rôle | vCPU | RAM |
| ---: | --- | --- | ---: | ---: |
| 100 | `k3s-control-plane-1` | Control plane | 2 | 4 096 Mo |
| 101 | `k3s-worker-1` | Worker | 2 | 4 096 Mo |
| 102 | `k3s-worker-2` | Worker | 2 | 4 096 Mo |

## Rôle des fichiers

| Fichier | Rôle |
| --- | --- |
| `versions.tf` | Définit la version minimale de Terraform/OpenTofu et verrouille le provider `bpg/proxmox` sur la série `0.111.x`. |
| `provider.tf` | Configure la connexion à l'API Proxmox avec l'URL et le jeton fournis par les variables Terraform. |
| `variables.tf` | Déclare les paramètres modifiables : nœud, stockage, bridge réseau, template, IDs, nombre de vCPU et quantité de RAM. Il valide aussi les valeurs sensibles, comme l'unicité des IDs. |
| `cloned-vm.tf` | Décrit les trois VMs. Une ressource avec `for_each` clone le template `9000` pour créer la cheffe et les deux ouvrières avec Cloud-Init et DHCP. |
| `outputs.tf` | Affiche après le déploiement l'ID, le nom et les adresses IPv4 détectées pour chaque VM. |
| `terraform.tfvars.example` | Sert de modèle pour créer le fichier local `terraform.tfvars` contenant l'URL et le jeton Proxmox. |
| `.terraform.lock.hcl` | Enregistre la version exacte du provider installée afin que tous les futurs déploiements utilisent la même version. Ce fichier doit être versionné. |
| `README.md` | Documente l'architecture, les fichiers et les commandes d'utilisation. |

Le fichier `terraform.tfstate`, créé lors du premier `apply`, est ignoré par Git, car il peut contenir des informations sensibles.

## Configurer les secrets

Terraform ne charge pas les fichiers `.env`. Pour une utilisation locale, copier le modèle :

```bash
cp terraform.tfvars.example terraform.tfvars
```

Renseigner ensuite les trois valeurs dans `terraform.tfvars` :

```hcl
proxmox_endpoint         = "https://proxmox.example.com:8006"
proxmox_api_token_id     = "terraform@pve!homelab"
proxmox_api_token_secret = "secret-du-token"
```

Depuis l'ancien `.env`, recopier `url` dans `proxmox_endpoint`, `tokenId` dans `proxmox_api_token_id` et `secret` dans `proxmox_api_token_secret`.

`terraform.tfvars` est automatiquement chargé par Terraform et ignoré par Git. L'attribut `sensitive = true` empêche l'affichage accidentel du jeton dans les sorties, mais ne chiffre ni le fichier ni le state.

Dans un environnement CI, ne pas créer de fichier et utiliser plutôt des variables d'environnement protégées :

```bash
export TF_VAR_proxmox_endpoint="https://proxmox.example.com:8006"
export TF_VAR_proxmox_api_token_id="terraform@pve!homelab"
export TF_VAR_proxmox_api_token_secret="secret-du-token"
```

## Utilisation

```bash
cd terraform
tofu init
tofu plan
tofu apply
```

Remplacer `tofu` par `terraform` si Terraform est installé à la place d'OpenTofu.

## Modifier la RAM

La RAM de la cheffe et des ouvrières se modifie indépendamment avec la variable `vm_memory_mb`. Par exemple, pour conserver 4 Go sur la cheffe et passer chaque ouvrière à 8 Go :

```bash
tofu apply -var='vm_memory_mb={control_plane=4096,worker=8192}'
```

Les valeurs non secrètes peuvent aussi être surchargées dans un fichier `terraform.tfvars`.
