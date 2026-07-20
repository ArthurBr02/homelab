# Infrastructure Proxmox du cluster k3s

Cette configuration clone le template Ubuntu Cloud-Init `9000` pour créer :

| ID | Nom | Rôle | Adresse IPv4 | vCPU | RAM |
| ---: | --- | --- | --- | ---: | ---: |
| 9001 | `k3s-control-plane-1` | Control plane | `192.168.1.100/24` | 2 | 4 096 Mo |
| 9002 | `k3s-worker-1` | Worker | `192.168.1.101/24` | 2 | 4 096 Mo |
| 9003 | `k3s-worker-2` | Worker | `192.168.1.102/24` | 2 | 4 096 Mo |

## Rôle des fichiers

| Fichier | Rôle |
| --- | --- |
| `versions.tf` | Définit la version minimale de Terraform/OpenTofu et verrouille le provider `bpg/proxmox` sur la série `0.111.x`. |
| `provider.tf` | Configure la connexion à l'API Proxmox avec l'URL et le jeton fournis par les variables Terraform. |
| `variables.tf` | Déclare les paramètres modifiables : nœud, stockage, réseau, template, IDs, ressources et accès aux VMs. Il valide aussi les valeurs comme l'unicité des IDs. |
| `cloned-vm.tf` | Décrit les trois VMs. Une ressource avec `for_each` clone le template `9000` pour créer la cheffe et les deux ouvrières avec Cloud-Init et DHCP. |
| `outputs.tf` | Affiche après le déploiement l'ID, le nom et les adresses IPv4 détectées pour chaque VM. |
| `cloud-init.tf` | Rend les templates avec `local_sensitive_file`, puis envoie les snippets à Proxmox avec `source_file`. |
| `terraform.tfvars.example` | Sert de modèle pour créer le fichier local `terraform.tfvars` contenant l'URL et le jeton Proxmox. |
| `.terraform.lock.hcl` | Enregistre la version exacte du provider installée afin que tous les futurs déploiements utilisent la même version. Ce fichier doit être versionné. |
| `README.md` | Documente l'architecture, les fichiers et les commandes d'utilisation. |

Le fichier `terraform.tfstate`, créé lors du premier `apply`, est ignoré par Git, car il peut contenir des informations sensibles.

L'envoi des snippets Cloud-Init nécessite également un accès SSH à l'hôte Proxmox. Le provider utilise `root` et les clés chargées dans l'agent SSH local :

```bash
ssh-add ~/.ssh/id_rsa
ssh root@192.168.1.32
```

La deuxième commande doit fonctionner sans demander le mot de passe de `root` avant de lancer `tofu apply`.

Les snippets utilisent `source_file` avec `upload_mode = "sftp"`. Ce mode évite de transmettre le YAML sur le stdin du shell `zsh` de `root`, qui interpréterait son contenu comme des commandes sur l'hôte Proxmox.

Les fichiers locaux `*.generated.yaml` contiennent le token k3s et éventuellement le mot de passe de la VM. Ils sont créés avec les permissions `0600` et ignorés par Git.

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

## Accéder aux VMs

Terraform injecte la clé publique `~/.ssh/id_rsa.pub` dans le compte `ubuntu`. Le chemin se modifie dans `terraform.tfvars` si une autre clé doit être utilisée :

```hcl
ssh_public_key_path = "~/.ssh/id_rsa.pub"
```

Après le déploiement, se connecter en SSH :

```bash
ssh ubuntu@192.168.1.100
ssh ubuntu@192.168.1.101
ssh ubuntu@192.168.1.102
```

La console Proxmox utilise un port série déclaré dans `cloned-vm.tf`. Pour pouvoir s'y authentifier avec `ubuntu`, définir également un mot de passe local dans `terraform.tfvars` :

```hcl
vm_password = "remplacer-par-un-mot-de-passe-fort"
```

Le mot de passe est marqué comme sensible, mais reste présent dans `terraform.tfvars` et dans le state. La connexion SSH par clé reste préférable.

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

## Configuration réseau

Les trois VMs utilisent des adresses statiques sur le réseau `192.168.1.0/24`, avec `192.168.1.254` comme passerelle et serveur DNS par défaut. Ces valeurs sont définies par `vm_ipv4_addresses`, `proxmox_network_gateway` et `proxmox_dns_servers` dans `variables.tf`.

Vérifier que les adresses `.100`, `.101` et `.102` sont exclues de la plage DHCP ou réservées avant d'appliquer la configuration.
