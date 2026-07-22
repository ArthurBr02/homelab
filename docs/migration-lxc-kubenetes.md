# Plan de migration — homelab k3s

> **Dimensionnement de départ :** 3 VMs à 4 Go (12 Go sur 20 disponibles), à augmenter au fur et à mesure que les LXC s'éteignent.

## 1. Préparer le terrain

- Supprimer le LXC 103 (Minecraft) :

  ```bash
  pct destroy 103
  ```

  Cela ne libère pas de mémoire (52 Mo consommés), c'est simplement du ménage.

- Vérifier avec `free -h` que tu es toujours autour de 20 Go disponibles.

## 2. Créer le dépôt Git — la source de vérité

- Créer un dépôt Git privé nommé `homelab`, avec deux dossiers :

  ```text
  homelab/
  ├── terraform/
  └── kubernetes/
  ```

- Ajouter un `.gitignore` qui exclut `terraform.tfstate` et tout fichier de secret. Ne jamais stocker de mot de passe en clair dans Git.
- À partir d'ici, chaque changement suit ce cycle :

  ```text
  modifier → git commit → git push
  ```

## 3. Créer les trois machines avec Terraform

- Installer Terraform (ou OpenTofu) sur ton PC.
- Créer un utilisateur dédié dans Proxmox avec un jeton d'accès (API token).
- Préparer une image Ubuntu Server « cloud-init » dans Proxmox : ce sera le modèle cloné par Terraform.
- Décrire les trois VMs dans `terraform/` avec le provider `bpg/proxmox` :
  - une cheffe ;
  - deux ouvrières ;
  - 4 Go de RAM et 2 vCPU chacune.
- Définir la RAM dans une variable, car elle changera souvent.
- Créer les machines :

  ```bash
  terraform plan
  terraform apply
  ```

  Les trois machines doivent apparaître sans intervention dans l'interface. Faire ensuite un commit et un push.

### Validation

Exécuter :

```bash
terraform destroy
terraform apply
```

Si tout revient à l'identique, l'infrastructure est réellement décrite sous forme de code.

> Effectuer ce test maintenant, avant d'héberger des données réelles dans le cluster.

## 4. Automatiser l'installation de k3s avec Cloud-Init

Le template contient le moteur Cloud-Init, mais sa configuration n'est pas figée dans le template. À chaque clone, Proxmox attache un nouveau disque Cloud-Init ; Terraform peut donc fournir un `user-data` différent à chaque VM.

Répartir les responsabilités ainsi :

- **Terraform** crée les VMs et leur attache le `user-data` Cloud-Init ;
- **Cloud-Init** configure le système, installe k3s et rattache le nœud au cluster ;
- **Argo CD** installe ensuite Longhorn, Prometheus et les applications Kubernetes ;
- les **snapshots etcd** permettent de restaurer l'état du cluster.

### Répartition des modifications par fichier

| Fichier | Modification |
| --- | --- |
| `terraform/variables.tf` | Déclarer `k3s_token`, le compte de connexion, la clé SSH, le mot de passe facultatif, les IPs statiques, la passerelle et les DNS. |
| `terraform/terraform.tfvars` | Renseigner les secrets et le chemin de la clé publique. Ce fichier reste local et ignoré par Git. |
| `terraform/terraform.tfvars.example` | Ajouter uniquement des valeurs factices et non sensibles. |
| `terraform/cloud-init.tf` | Rendre la configuration propre à chaque nœud dans un fichier local protégé, puis envoyer les snippets à Proxmox. |
| `terraform/cloud-init/k3s.yaml.tftpl` | Décrire les commandes exécutées par Cloud-Init dans chaque VM. |
| `terraform/cloud-init/k3s.yaml.tftpl` | Attacher le snippet correspondant à chaque VM dans le bloc `initialization`. |

### Préparer le stockage des snippets

Dans Proxmox, ouvrir **Datacenter → Storage → media-storage → Edit → Content**, puis activer **Snippets**.

Ajouter également le privilège `Datastore.AllocateTemplate` au rôle Proxmox utilisé par Terraform afin qu'il puisse envoyer les snippets sur ce stockage.

Le provider envoie les snippets par SSH. Dans `terraform/provider.tf`, déclarer explicitement l'utilisateur `root` et l'agent SSH :

```hcl
provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = var.proxmox_insecure

  ssh {
    agent    = true
    username = "root"
  }
}
```

Charger la clé privée dans l'agent, puis vérifier l'accès avant d'exécuter Terraform :

```bash
ssh-add ~/.ssh/id_rsa
ssh root@192.168.1.32
```

La connexion doit fonctionner avec la clé, sans demander le mot de passe de `root`. Le fichier `~/.ssh/config` n'est pas pris en compte par le provider.

L'adresse du serveur k3s doit être stable. Les adresses statiques sont déclarées dans `terraform/variables.tf` avec `vm_ipv4_addresses`, puis appliquées dans le bloc `initialization` de `terraform/cloned-vm.tf`.

### Configurer l'accès aux VMs

Dans `terraform/cloned-vm.tf`, déclarer la console série dans la ressource `proxmox_virtual_environment_vm.k3s` :

```hcl
serial_device {
  device = "socket"
}

vga {
  type = "serial0"
}
```

Sans `serial_device`, Proxmox essaie d'afficher `serial0` alors que le périphérique n'existe pas, ce qui produit une console vide ou inaccessible.

Dans `terraform/variables.tf`, déclarer l'utilisateur, la clé publique et le mot de passe console facultatif :

```hcl
variable "vm_username" {
  type    = string
  default = "ubuntu"
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_rsa.pub"
}

variable "vm_password" {
  type      = string
  default   = null
  sensitive = true
  nullable  = true
}
```

Dans `terraform/terraform.tfvars`, choisir la clé publique locale. Ajouter `vm_password` uniquement pour se connecter depuis la console Proxmox :

```hcl
ssh_public_key_path = "~/.ssh/id_rsa.pub"
vm_password         = "remplacer-par-un-mot-de-passe-fort"
```

> L'image Ubuntu Cloud verrouille la connexion par mot de passe par défaut. Sans `vm_password`, la console peut afficher l'écran de connexion sans permettre de s'authentifier. La connexion SSH par clé reste préférable.

### Déclarer le secret k3s

Dans `terraform/variables.tf`, ajouter :

```hcl
variable "k3s_token" {
  description = "Jeton partagé par les nœuds du cluster k3s."
  type        = string
  sensitive   = true
}
```

Dans `terraform/terraform.tfvars`, renseigner la vraie valeur :

```hcl
k3s_token = "remplacer-par-un-secret-long-et-aleatoire"
```

Dans `terraform/terraform.tfvars.example`, ajouter seulement une valeur factice :

```hcl
k3s_token = "remplacer-par-le-secret-k3s"
```

> `sensitive = true` masque la valeur dans les sorties, mais ne chiffre ni le fichier `terraform.tfvars`, ni le state Terraform, ni le snippet stocké dans Proxmox. Protéger ces trois emplacements et prévoir un backend distant chiffré.

### Définir le rôle de chaque nœud

Créer `terraform/cloud-init.tf`. Commencer par y définir le rôle de chaque nœud pour l'architecture initiale composée d'un serveur et de deux agents :

```hcl
locals {
  k3s_bootstrap = {
    control_plane = {
      install_exec = "server"
      config       = "cluster-init: true"
    }
    worker_1 = {
      install_exec = "agent"
      config       = "server: https://192.168.1.100:6443"
    }
    worker_2 = {
      install_exec = "agent"
      config       = "server: https://192.168.1.100:6443"
    }
  }
}
```

L'adresse `192.168.1.100` doit correspondre à `vm_ipv4_addresses.control_plane` dans `terraform/variables.tf`.

### Générer les snippets Cloud-Init

Dans le même fichier `terraform/cloud-init.tf`, sous le bloc `locals`, rendre d'abord un fichier local par VM. `local_sensitive_file` évite un bug de `source_raw` qui peut envoyer un fichier de zéro octet avec `bpg/proxmox` 0.111.1 :

```hcl
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
```

Ajouter `*.generated.yaml` au fichier `.gitignore`, car ces fichiers contiennent des secrets.

Toujours dans `terraform/cloud-init.tf`, envoyer ensuite chaque fichier à Proxmox :

```hcl
resource "proxmox_virtual_environment_file" "cloud_init" {
  for_each = local.k3s_vms

  content_type = "snippets"
  datastore_id = var.proxmox_datastore_id
  node_name     = var.proxmox_node_name
  upload_mode   = "sftp"

  source_file {
    path      = local_sensitive_file.cloud_init[each.key].filename
    file_name = "${each.value.name}-cloud-init.yaml"
  }
}
```

Utiliser impérativement `source_file` avec `upload_mode = "sftp"` lorsque le compte `root` de Proxmox utilise `zsh`. Le mode `stream` transmet le YAML sur l'entrée standard du shell et peut provoquer son exécution accidentelle directement sur l'hôte Proxmox.

Dans `terraform/cloned-vm.tf`, attacher le snippet au bloc `initialization` existant de la ressource `proxmox_virtual_environment_vm.k3s` :

```hcl
initialization {
  datastore_id      = var.proxmox_datastore_id
  interface         = "ide0"
  user_data_file_id = proxmox_virtual_environment_file.cloud_init[each.key].id

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
```

Créer ensuite le fichier `terraform/cloud-init/k3s.yaml.tftpl` avec le contenu suivant :

```yaml
#cloud-config
hostname: ${jsonencode(hostname)}

users:
  - name: ${jsonencode(username)}
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - ${jsonencode(ssh_public_key)}

%{ if vm_password != null ~}
ssh_pwauth: true
chpasswd:
  expire: false
  users:
    - name: ${jsonencode(username)}
      password: ${jsonencode(vm_password)}
      type: text
%{ endif ~}

packages:
  - curl

write_files:
  - path: /etc/rancher/k3s/config.yaml
    permissions: "0600"
    content: |
      token: ${jsonencode(k3s_token)}
      ${indent(6, k3s_config)}

runcmd:
  - curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=${install_exec} sh -
```

Cloud-Init s'exécute au premier démarrage. Si les agents démarrent avant le serveur, le service k3s réessaie de se connecter jusqu'à ce que l'API soit disponible.

Après le déploiement, se connecter en SSH :

```bash
ssh ubuntu@192.168.1.100
ssh ubuntu@192.168.1.101
ssh ubuntu@192.168.1.102
```

Pour utiliser l'interface Proxmox, ouvrir la VM, puis **Console** et sélectionner **xterm.js**. Se connecter avec l'utilisateur `ubuntu` et la valeur de `vm_password`.

Si les VMs ont déjà démarré avant l'ajout de ces paramètres, Cloud-Init peut considérer leur initialisation comme terminée. Tant qu'elles ne contiennent aucune donnée, les recréer avec `tofu apply -replace=...` est plus fiable que modifier manuellement chaque VM.

### Prévoir la haute disponibilité

Avec un seul serveur et deux agents, Cloud-Init réinstalle automatiquement k3s si la VM est recréée, mais l'état Kubernetes disparaît avec le serveur. Les agents ne possèdent pas de copie de cet état.

Pour tolérer la perte d'une VM, utiliser trois nœuds `server` avec l'etcd embarqué :

- le premier initialise le cluster avec `cluster-init: true` ;
- les deux autres utilisent `install_exec = "server"` et rejoignent le premier ;
- kube-vip fournit une adresse stable à l'API Kubernetes ;
- les snapshots etcd sont sauvegardés régulièrement vers MinIO.

Lors du remplacement d'un serveur, celui-ci doit rejoindre l'adresse virtuelle du cluster existant. Si les trois serveurs sont perdus, restaurer un snapshot etcd avant de rattacher les autres nœuds.

## 5. Monter et valider le cluster

- Appliquer la configuration Terraform : Cloud-Init installe automatiquement k3s sur les trois VMs.
- Sur chaque VM, attendre la fin de Cloud-Init :

  ```bash
  cloud-init status --wait
  ```

- Vérifier le service avec `systemctl status k3s` sur le serveur et `systemctl status k3s-agent` sur les agents.
- Vérifier l'état des nœuds :

  ```bash
  kubectl get nodes
  ```

  Le résultat doit contenir trois lignes avec l'état `Ready`.

## 6. Faire un premier test manuel

- Mettre un bot du LXC 108 dans une image Docker.
- Créer `kubernetes/apps/bot-x/deployment.yaml`. Un bot n'a besoin que de ce fichier.
- Faire un commit et un push.
- Déployer et vérifier que le bot répond sur Discord :

  ```bash
  kubectl apply -f kubernetes/apps/bot-x/deployment.yaml
  ```

- Éteindre volontairement une ouvrière : le bot doit redémarrer seul sur l'autre.

## 7. Passer en pilote automatique

Objectif : que **rien** ne vive uniquement dans une VM. Si une machine, ou le cluster entier, est reconstruite, tout doit se reconstituer à partir de Git.

- Installer Argo CD dans le cluster et le relier au dépôt Git. Son rôle est de garder le cluster identique à ce que Git décrit.
- Installer Sealed Secrets afin de chiffrer les tokens Discord et les identifiants avant de les commiter.
- Confier à Argo CD le bot créé à l'étape précédente.

### Comprendre ce qui persiste et ce qui disparaît

Le problème actuel : le bot a été démarré à la main. Son `deployment.yaml` est bien dans Git, mais ses **secrets** ont été créés en impératif directement sur le control plane :

- `kubernetes/auth/auth-ghcr-io.sh` crée le secret `ghcr-login-secret` avec des variables d'environnement, sans jamais toucher Git ;
- `kubernetes/apps/bot-maison/bot-maison-secret.yaml` contient le token Discord, mais il est **ignoré par Git** (`*secret.yaml` dans `.gitignore`).

Ces secrets ne vivent donc qu'à deux endroits : l'`etcd` du cluster et des fichiers locaux sur la VM. Les deux disparaissent à la reconstruction.

| Élément | Où il vit aujourd'hui | Survit à une reconstruction ? |
| --- | --- | --- |
| `deployment.yaml` du bot | Git | Oui |
| Configuration Terraform, Cloud-Init | Git | Oui |
| `ghcr-login-secret` (identifiant GHCR) | `etcd` + script local | **Non** |
| `bot-maison-secret` (token Discord) | `etcd` + fichier gitignoré | **Non** |
| État Kubernetes (`etcd`) du control plane | VM control plane uniquement | **Non** (voir la mise en garde plus bas) |

L'objectif de cette étape est de faire passer chaque ligne de ce tableau à « Oui ».

### Installer Argo CD

Argo CD lit le dépôt Git et applique tout seul son contenu au cluster. C'est lui qui remplace les `kubectl apply` manuels.

1. Créer son namespace et l'installer depuis le manifeste officiel :

   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```

   > Cette commande d'installation est le seul geste manuel restant. Note-la dans `kubernetes/argocd/README.md` : après une reconstruction totale, c'est la première chose à rejouer, avant qu'Argo CD ne reprenne la main sur le reste.

2. Récupérer le mot de passe administrateur initial :

   ```bash
   kubectl -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath="{.data.password}" | base64 -d
   ```

3. Ouvrir l'interface depuis l'extérieur du réseau, via un tunnel SSH.

   Par défaut, le serveur Argo CD n'est pas exposé (service `ClusterIP`). La commande `kubectl port-forward` publie le port sur le `localhost` de la machine où elle s'exécute — le control plane — et non sur ton poste distant. Un tunnel SSH relie les deux sans rien exposer sur le réseau.

   Depuis ton poste distant, ouvrir le tunnel vers le control plane :

   ```bash
   ssh -L 8080:localhost:8080 ubuntu@192.168.1.100
   ```

   Dans cette même session SSH (donc sur le control plane), lancer le port-forward :

   ```bash
   kubectl port-forward -n argocd svc/argocd-server 8080:443
   ```

   Laisser les deux commandes actives, puis ouvrir `https://localhost:8080` dans le navigateur du poste distant. Le chemin est : navigateur → `localhost:8080` (tunnel SSH) → `localhost:8080` du control plane (port-forward) → service Argo CD.

   - Certificat auto-signé : accepter l'avertissement du navigateur.
   - Utilisateur : `admin`.
   - Mot de passe : la valeur récupérée à l'étape précédente.

   > Cet accès est temporaire : il ne dure que le temps où les deux commandes tournent, et rien n'est publié sur le réseau. Exposer Argo CD en permanence (via un Ingress derrière le Nginx Proxy Manager de la LXC 111) est une décision à part, car cela met l'interface d'administration face au réseau. À décider plus tard, pas maintenant.

4. Après la première connexion, changer le mot de passe puis supprimer le secret initial devenu inutile :

   ```bash
   argocd account update-password
   kubectl -n argocd delete secret argocd-initial-admin-secret
   ```

   > `argocd account update-password` nécessite le client `argocd` (`brew install argocd`), connecté via `argocd login localhost:8080 --username admin --insecure` pendant que le tunnel est ouvert. On peut aussi changer le mot de passe directement dans l'interface web (User Info → Update Password).

5. Déclarer une application racine (patron « app of apps ») qui pointe Argo CD vers le dossier `kubernetes/` du dépôt. Créer `kubernetes/argocd/root-app.yaml` :

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: root
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://github.com/arthurbr02/homelab.git
       targetRevision: main
       path: kubernetes/apps
       directory:
         recurse: true
     destination:
       server: https://kubernetes.default.svc
       namespace: default
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
   ```

   `prune: true` supprime ce qui n'est plus dans Git ; `selfHeal: true` annule toute modification faite à la main dans le cluster. Git redevient la seule source de vérité.

   > Deux réglages faciles à oublier, qui donnent une app racine « Synced » mais vide :
   >
   > - `directory.recurse: true` : sans lui, Argo CD ne lit que les YAML **directement** dans `kubernetes/apps/`, et ignore les sous-dossiers comme `kubernetes/apps/bot-maison/`. Résultat : arbre vide, aucune ressource déployée.
   > - `destination.namespace` : les manifestes du bot n'indiquent pas de namespace. Argo CD a besoin d'une cible, sinon il refuse la ressource avec `InvalidSpecError: Namespace ... is missing`.

6. Appliquer une seule fois cette application racine :

   ```bash
   kubectl apply -f kubernetes/argocd/root-app.yaml
   ```

   À partir de là, Argo CD déploie et surveille tout ce qui se trouve sous `kubernetes/apps/`.

### Installer Sealed Secrets

Un `Secret` Kubernetes classique n'est **pas** chiffré : sa valeur est seulement encodée en base64, donc lisible par quiconque. On ne peut pas le commiter tel quel. Sealed Secrets résout ça : un contrôleur dans le cluster détient une clé privée, et l'outil `kubeseal` chiffre les secrets avec la clé publique correspondante. Le résultat chiffré (`SealedSecret`) peut être poussé dans Git sans risque ; seul le contrôleur peut le déchiffrer.

1. Installer le contrôleur dans le cluster :

   ```bash
   kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/controller.yaml
   ```

2. Installer l'outil `kubeseal` sur ton PC (celui qui a accès à `kubectl`) :

   ```bash
   brew install kubeseal
   ```

### Convertir les secrets manuels en Sealed Secrets

L'idée : produire le `Secret` en clair **localement**, le chiffrer immédiatement avec `kubeseal`, ne commiter que la version chiffrée, puis jeter la version en clair. Le secret en clair ne touche jamais Git ni le disque durablement.

1. **Identifiant GHCR.** Remplacer l'exécution du script `auth-ghcr-io.sh` par un `SealedSecret` versionné :

   ```bash
   kubectl create secret docker-registry ghcr-login-secret \
     --docker-server=https://ghcr.io \
     --docker-username="$GHCR_USERNAME" \
     --docker-password="$GHCR_TOKEN" \
     --docker-email="$GHCR_EMAIL" \
     --dry-run=client -o yaml \
     | kubeseal --format yaml \
     > kubernetes/apps/auth/ghcr-login-sealed.yaml
   ```

   `--dry-run=client` génère le YAML sans rien créer dans le cluster ; le tube l'envoie directement à `kubeseal`.

2. **Token Discord.** Même principe à partir du secret existant :

   ```bash
   kubectl create secret generic bot-maison-secret \
     --from-literal=token="$DISCORD_TOKEN" \
     --dry-run=client -o yaml \
     | kubeseal --format yaml \
     > kubernetes/apps/bot-maison/bot-maison-sealed.yaml
   ```

3. Commiter les deux fichiers `*-sealed.yaml`. Ils sont chiffrés, donc sûrs dans Git.

   > Vérifier que le motif `*sealed.yaml` n'est **pas** attrapé par le `.gitignore`. La règle actuelle `*secret.yaml` ne bloque pas `*-sealed.yaml`, mais garde ce point en tête si tu renommes les fichiers.

4. Une fois les `SealedSecret` en place et déployés par Argo CD, le script `auth-ghcr-io.sh` et le fichier `bot-maison-secret.yaml` ne servent plus qu'à la génération. Ils peuvent rester en `.example`, mais ne sont plus nécessaires au fonctionnement du cluster.

> **Piège de migration : un Secret créé à la main empêche l'adoption.** Si un `Secret` du même nom existait déjà (créé en impératif avant la migration), le contrôleur refuse de l'écraser et le `SealedSecret` reste `Degraded` :
>
> ```text
> failed update: Resource "bot-maison-secret" already exists and is not managed by SealedSecret
> ```
>
> Autoriser le contrôleur à reprendre le Secret existant en l'annotant, puis relancer le contrôleur :
>
> ```bash
> kubectl annotate secret <nom> -n <namespace> \
>   sealedsecrets.bitnami.com/managed="true" --overwrite
> kubectl delete pod -n kube-system -l name=sealed-secrets-controller
> ```
>
> Le redémarrage est nécessaire : après plusieurs échecs le contrôleur « abandonne » (`giving up`) et ne retente pas tant que le spec du `SealedSecret` ne change pas (`update suppressed, no changes in spec`). Ce cas ne concerne **que** la migration d'un existant : sur un cluster reconstruit de zéro, aucun Secret manuel n'entre en conflit, le contrôleur crée le Secret du premier coup.

### Sauvegarder la clé de déchiffrement Sealed Secrets

C'est le point le plus important, et celui qu'on oublie presque toujours.

Les `SealedSecret` dans Git ne sont déchiffrables que par **la clé privée du contrôleur Sealed Secrets**. Cette clé est générée aléatoirement à la première installation et vit dans l'`etcd` du cluster. Si le cluster est reconstruit de zéro, le contrôleur génère une **nouvelle** clé, incompatible avec les `SealedSecret` déjà chiffrés. Résultat : Git est intact, mais plus aucun secret ne peut être relu.

Il faut donc sauvegarder cette clé **hors du cluster**.

1. Exporter la clé (elle porte un label dédié) :

   ```bash
   kubectl get secret -n kube-system \
     -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
     -o yaml > sealed-secrets-key-backup.yaml
   ```

2. Stocker `sealed-secrets-key-backup.yaml` dans un endroit chiffré et **hors du cluster** : gestionnaire de mots de passe, ou fichier chiffré (`age`, `gpg`) sur un disque séparé.

   > Ne jamais commiter ce fichier dans Git. Il contient la clé privée en clair : quiconque l'obtient peut déchiffrer tous tes `SealedSecret`. C'est l'exact opposé des `SealedSecret` eux-mêmes, qui, eux, sont faits pour aller dans Git.

3. **Restauration**, sur un cluster reconstruit, avant de laisser Argo CD synchroniser :

   ```bash
   kubectl apply -f sealed-secrets-key-backup.yaml
   kubectl delete pod -n kube-system -l name=sealed-secrets-controller
   ```

   Le contrôleur redémarre avec l'ancienne clé et redevient capable de déchiffrer les `SealedSecret` du dépôt.

### Récupération après reconstruction

Une fois Argo CD et Sealed Secrets en place, la reconstruction d'un cluster neuf ne se « retape » pas à la main : le seul geste manuel est un **bootstrap scripté**, tout le reste découle de Git.

Le script `kubernetes/bootstrap.sh` enchaîne les quatre étapes :

1. installer Argo CD ;
2. installer le contrôleur Sealed Secrets ;
3. **restaurer la clé de déchiffrement** depuis la sauvegarde hors cluster, puis relancer le contrôleur ;
4. appliquer l'application racine `root-app.yaml`, qui met Argo CD au travail.

```bash
SEALED_SECRETS_KEY_BACKUP=/chemin/vers/sealed-secrets-key-backup.yaml \
  ./kubernetes/bootstrap.sh
```

Après ça, Argo CD tire toutes les applications depuis Git et le contrôleur déchiffre tous les `SealedSecret` automatiquement. Rien à re-sceller, aucun secret à recréer à la main.

> Ce script est le point d'entrée unique après une perte. Le garder versionné dans Git ; noter le chemin de la sauvegarde de clé (elle, hors Git). Sans cette clé, l'étape 3 échoue volontairement, car sans elle tous les `SealedSecret` seraient illisibles.

### Mise en garde : ce que Git ne reconstruit pas

Tant que le cluster tourne avec un **seul** nœud `server`, reconstruire cette VM détruit l'`etcd`, donc tout l'état Kubernetes. Argo CD et Sealed Secrets réparent la partie « configuration et secrets », mais pas la perte de l'`etcd` lui-même — l'`etcd` n'est pas dans Git.

Deux protections, complémentaires, déjà prévues plus haut :

- **Restaurer un snapshot etcd** (voir « Prévoir la haute disponibilité » à l'étape 4) rétablit l'état exact du cluster ;
- **Passer à trois nœuds `server`** avec l'etcd embarqué : la perte d'une VM ne fait plus perdre l'état, les deux autres nœuds le conservent. C'est le vrai remède : un nœud peut tomber sans aucune intervention.

La chaîne de récupération complète après une perte devient :

```text
Terraform recrée les VMs
  → Cloud-Init réinstalle k3s (+ restauration d'un snapshot etcd si nécessaire)
  → ./kubernetes/bootstrap.sh (Argo CD + Sealed Secrets + clé + app racine)
  → Argo CD resynchronise apps + SealedSecret depuis Git
  → les secrets sont déchiffrés, les applications redémarrent
```

### Validation

1. **Reproductibilité des applications.** Modifier le YAML du bot, pousser le changement et vérifier qu'Argo CD le déploie sans utiliser `kubectl`.
2. **Reproductibilité des secrets.** Supprimer à la main le secret déchiffré (`kubectl delete secret bot-maison-secret`) et vérifier que Sealed Secrets le régénère à partir du `SealedSecret` du dépôt.
3. **Test de la sauvegarde de clé.** Sur un cluster de test jetable : chiffrer un secret, supprimer le contrôleur et sa clé, restaurer la clé depuis la sauvegarde, et vérifier que le `SealedSecret` redevient déchiffrable. Tant que ce test n'a pas réussi, la sauvegarde n'est pas prouvée.

Désormais, le geste quotidien est :

```text
modifier → commit → push
```

## 8. Préparer le stockage des données

Trois couches, à installer **dans cet ordre** car chacune dépend de la précédente :

1. **Longhorn** — stockage bloc répliqué. Le stockage par défaut de k3s (`local-path`) attache un volume à un seul nœud ; si ce nœud tombe, le volume devient indisponible. Longhorn réplique les données au niveau bloc, pour que le volume suive le pod.
2. **MinIO** — stockage objet (dans le cluster, sur un volume Longhorn). Destination des sauvegardes de bases de données.
3. **CloudNativePG** — opérateur PostgreSQL : réplication, bascule, archivage WAL et restauration à un instant donné, avec sauvegardes vers MinIO.

> Tout passe par Argo CD (étape 7). Chaque composant est décrit par une ressource `Application` commitée dans `kubernetes/apps/<composant>/`, que l'app racine déploie automatiquement. On n'installe plus rien avec `helm install` à la main.
>
> Une ressource `Application` vit dans le namespace `argocd` : ses manifestes doivent donc porter `metadata.namespace: argocd` explicitement, sinon l'app racine les enverrait dans `default`.

### 8.1 Longhorn (stockage bloc répliqué)

**Prérequis système, dans Cloud-Init.** Longhorn a besoin de `open-iscsi` et `nfs-common` sur chaque nœud. Les ajouter au bloc `packages` de `terraform/cloud-init/k3s.yaml.tftpl` :

```yaml
packages:
  - curl
  - open-iscsi
  - nfs-common
```

**Disque dédié pour Longhorn.** Ajouter un second disque à chaque VM dans `terraform/cloned-vm.tf`, distinct du disque système :

```hcl
disk {
  datastore_id = var.proxmox_datastore_id
  interface    = "scsi1"
  size         = 100           # Go, à ajuster (media-storage = SSD 3.6T, large marge)
}
```

Puis, dans Cloud-Init, formater et monter ce disque sur `/var/lib/longhorn` (chemin de données par défaut de Longhorn). Ajouter au template :

```yaml
disk_setup:
  /dev/sdb:
    table_type: gpt
    layout: true
fs_setup:
  - device: /dev/sdb1
    filesystem: ext4
mounts:
  - [/dev/sdb1, /var/lib/longhorn, ext4, "defaults,nofail", "0", "2"]
```

> Vérifier le nom réel du disque (`/dev/sdb` vs `/dev/vdb`) selon le contrôleur (`scsi` → `sd*`, `virtio` → `vd*`). Un disque dédié isole les données du système et évite qu'une saturation Longhorn ne bloque l'OS.

**Déploiement via Argo CD.** Créer `kubernetes/apps/longhorn/application.yaml` :

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: longhorn
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.longhorn.io
    chart: longhorn
    targetRevision: 1.7.2          # épingler une version
    helm:
      values: |
        persistence:
          defaultClass: true       # Longhorn devient la StorageClass par défaut
          defaultClassReplicaCount: 3
        defaultSettings:
          defaultDataPath: /var/lib/longhorn
  destination:
    server: https://kubernetes.default.svc
    namespace: longhorn-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

> `defaultClass: true` fait de Longhorn la StorageClass par défaut, mais **ne retire pas** le statut par défaut de `local-path` (livré avec k3s) : Kubernetes refuse deux défauts. Retirer celui de `local-path` une fois Longhorn en place :
>
> ```bash
> kubectl patch storageclass local-path \
>   -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
> ```
>
> `defaultClassReplicaCount: 3` = une copie par nœud sur trois serveurs. Descendre à 2 si la place manque.

### 8.2 MinIO (stockage objet, dans le cluster)

Déployé dans le cluster, sur un volume Longhorn. Sert de destination aux sauvegardes de bases de données (**pas** aux snapshots etcd, voir 13.7).

**Identifiants via Sealed Secrets.** Générer le secret racine MinIO scellé (même méthode qu'à l'étape 7) :

```bash
kubectl create secret generic minio-root \
  --from-literal=rootUser="admin" \
  --from-literal=rootPassword="$MINIO_PASSWORD" \
  --namespace minio --dry-run=client -o yaml \
  | kubeseal --format yaml \
  > kubernetes/apps/minio/minio-root-sealed.yaml
```

**Déploiement via Argo CD.** Créer `kubernetes/apps/minio/application.yaml` (chart MinIO, stockage sur Longhorn, credentials tirées du secret scellé) :

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: minio
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.min.io/
    chart: minio
    targetRevision: 5.4.0           # épingler une version
    helm:
      values: |
        mode: standalone            # une instance pour commencer
        existingSecret: minio-root
        persistence:
          enabled: true
          storageClass: longhorn
          size: 20Gi
        buckets:
          - name: db-backups
            policy: none
  destination:
    server: https://kubernetes.default.svc
    namespace: minio
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Commiter d'abord `minio-root-sealed.yaml`, puis `application.yaml`, pour que le secret existe quand le pod démarre.

> `mode: standalone` = une seule instance MinIO. Suffisant pour des sauvegardes de homelab. Passer en mode distribué plus tard si le besoin de résilience objet apparaît.

### 8.3 CloudNativePG (PostgreSQL géré)

Un **opérateur** qui gère PostgreSQL à ta place : réplication, bascule automatique, archivage WAL, restauration à un instant donné. On ne crée jamais un `StatefulSet` PostgreSQL soi-même.

**Installer l'opérateur via Argo CD.** Créer `kubernetes/apps/cloudnative-pg/application.yaml` :

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cloudnative-pg
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://cloudnative-pg.github.io/charts
    chart: cloudnative-pg
    targetRevision: 0.23.0          # épingler une version
  destination:
    server: https://kubernetes.default.svc
    namespace: cnpg-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Définir une base par application.** L'opérateur installé, une base se décrit par une ressource `Cluster`, placée dans le dossier de l'application concernée (une base par app, elles évoluent ensemble). Exemple type, avec sauvegarde vers MinIO :

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: exemple-db
  namespace: exemple
spec:
  instances: 1                      # 1 pour commencer, 2 une fois Longhorn éprouvé (étape 12)
  storage:
    size: 10Gi
    storageClass: longhorn
  backup:
    barmanObjectStore:
      destinationPath: s3://db-backups/exemple-db
      endpointURL: http://minio.minio.svc:9000
      s3Credentials:
        accessKeyId:
          name: minio-app-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: minio-app-creds
          key: ACCESS_SECRET_KEY
    retentionPolicy: "30d"
```

> Les identifiants d'accès MinIO (`minio-app-creds`) sont un secret : le sceller avec `kubeseal` et le commiter, comme les autres. `instances: 1` au départ ; passer à `2` seulement après avoir validé Longhorn et équipé les nœuds (étape 12).

### Validation

1. **StorageClass par défaut** : `kubectl get storageclass` montre `longhorn (default)` et `local-path` sans le tag `(default)`.
2. **Volume répliqué** : créer un PVC de test, écrire un fichier, supprimer le pod, le recréer sur un autre nœud, et vérifier que le fichier est toujours là.
3. **Cycle de sauvegarde/restauration PostgreSQL** :
   1. Créer une base de test avec `instances: 1`.
   2. Y insérer des données.
   3. La détruire.
   4. La restaurer depuis la sauvegarde MinIO.

> Tant que cette restauration n'a pas fonctionné, ne migrer aucune donnée réelle.

## 9. Migrer les services

Respecter cet ordre :

1. **LXC 108 — bots**
   - Migrer les autres bots Discord, avec un dossier par bot.
   - Éteindre le LXC 108.

2. **LXC 114 — portfolio**
   - Créer `deployment.yaml`, `service.yaml` et `ingress.yaml`.
   - Faire pointer Nginx Proxy Manager (LXC 111) vers le cluster.
   - Éteindre le LXC 114.

3. **LXC 113 — n8n**
   - Sauvegarder ses données.
   - Créer le premier véritable volume persistant sur Longhorn.
   - Éteindre le LXC 113.

4. **LXC 117 — reseausocial**
   - Migrer le service le plus volumineux (60 Go).
   - Placer dans son dossier l'application et son objet `Cluster` CloudNativePG : une base par application, afin qu'elles évoluent ensemble.
   - Utiliser une seule instance dans un premier temps, avec une sauvegarde vers MinIO.
   - Éteindre le LXC 117.

5. **LXC 107 — Prometheus**
   - Le migrer en dernier.
   - Installer `kube-prometheus-stack` plutôt que déplacer l'installation existante.
   - Éteindre le LXC 107.

## 10. Augmenter la RAM progressivement

Après chaque LXC éteint :

1. Vérifier la mémoire disponible avec `free -h`.
2. Augmenter la variable de RAM dans le fichier Terraform.
3. Exécuter `terraform apply`.
4. Redémarrer la VM concernée.
5. Créer un commit pour ce palier afin que l'historique montre la croissance du cluster.

**Cible finale :**

- 8 Go par ouvrière ;
- 4 Go pour la cheffe.

## 11. Services qui ne migrent pas

Les services suivants restent dans des LXC :

| LXC | Service |
| ---: | --- |
| 116 | Pi-hole |
| 111 | Proxy |
| 102 | VPN |
| 101 | Ansible |
| 109 | Service Manager |

Ils constituent le socle de l'infrastructure. Si le DNS, le reverse proxy ou les outils d'administration étaient hébergés dans le cluster, une panne du cluster pourrait supprimer les moyens nécessaires à sa réparation.

## 12. Finaliser

- Passer les bases de données à `instances: 2`, une fois Longhorn opérationnel et les workers équipés de 8 Go de RAM.
- Effectuer un test réel de bascule : arrêter le nœud qui héberge le primaire PostgreSQL et chronométrer la reprise.
- Déplacer le fichier d'état Terraform vers un backend distant (S3 ou MinIO).
- Configurer les sauvegardes Proxmox des trois VMs du cluster.

### Vérification finale

Le dépôt Git décrit-il toute l'infrastructure ?

```text
Machine morte → Terraform recrée la VM → Cloud-Init réinstalle k3s → le nœud rejoint le cluster → Argo CD redéploie le reste
```

## 13. Passer à trois serveurs (haute disponibilité)

Jusqu'ici le cluster tourne avec **un** nœud `server` et **deux** `agent`. Perdre le serveur, c'est perdre l'`etcd`, donc tout l'état Kubernetes. Cette étape transforme les deux agents en `server`, pour obtenir **trois nœuds `server` avec etcd embarqué** : le quorum est de 2 sur 3, donc la perte d'une VM ne fait plus rien perdre.

> À faire idéalement **avant** le test de bascule de l'étape 12 : sans HA, ce test n'a pas de sens.

### Prérequis

- Les deux ex-agents disposent d'assez de RAM (cible 8 Go, voir étape 10) : un `server` porte l'API et l'etcd, plus gourmand qu'un simple agent.
- MinIO est disponible (étape 8) pour y envoyer les snapshots etcd.
- Avec trois `server`, la distinction « cheffe / ouvrières » disparaît : les trois nœuds ont le même rôle et exécutent aussi les charges applicatives. Revoir la cible RAM en conséquence (trois nœuds équivalents).

### 13.1 Réserver une adresse IP virtuelle pour l'API

Aujourd'hui, tout pointe sur `192.168.1.100`, l'IP du premier serveur. Si ce nœud tombe, cette adresse disparaît. Il faut une **IP virtuelle (VIP)** qui « flotte » sur les trois serveurs, portée par **kube-vip**.

- Choisir une IP libre du réseau, **hors plage DHCP**, par exemple `192.168.1.99`. La réserver dans le Pi-hole / routeur pour qu'aucune autre machine ne la prenne.
- Cette VIP deviendra l'adresse unique de l'API Kubernetes, pour les nœuds comme pour `kubectl`.

Déclarer la VIP dans `terraform/variables.tf` :

```hcl
variable "k3s_api_vip" {
  description = "Adresse IP virtuelle stable de l'API Kubernetes (portée par kube-vip)."
  type        = string
  default     = "192.168.1.99"
}
```

### 13.2 Rendre le certificat de l'API valide pour la VIP

L'API k3s ne présente un certificat valide que pour les adresses déclarées en `tls-san`. Sans cela, joindre le cluster par la VIP échoue avec une erreur de certificat.

Dans le template `terraform/cloud-init/k3s.yaml.tftpl`, ajouter la VIP au fichier `config.yaml` généré, sur **tous** les nœuds :

```yaml
write_files:
  - path: /etc/rancher/k3s/config.yaml
    permissions: "0600"
    content: |
      token: ${jsonencode(k3s_token)}
      tls-san:
        - ${jsonencode(k3s_api_vip)}
      ${indent(6, k3s_config)}
```

Passer `k3s_api_vip` au template dans `local_sensitive_file.cloud_init` (`terraform/cloud-init.tf`), à côté des autres variables :

```hcl
k3s_api_vip = var.k3s_api_vip
```

### 13.3 Déployer kube-vip sur les serveurs

k3s déploie automatiquement tout manifeste déposé dans `/var/lib/rancher/k3s/server/manifests/`. On y place kube-vip pour qu'il monte la VIP dès le démarrage du premier serveur.

Générer le manifeste kube-vip une fois (sur ton PC), en mode ARP, avec l'interface réseau des VMs (souvent `eth0`) :

```bash
kube-vip manifest daemonset \
  --interface eth0 \
  --address 192.168.1.99 \
  --controlplane \
  --arp \
  --leaderElection > terraform/cloud-init/kube-vip.yaml
```

Puis, dans le template Cloud-Init, écrire ce manifeste **uniquement sur les nœuds `server`**, via `write_files` :

```yaml
%{ if install_exec == "server" ~}
  - path: /var/lib/rancher/k3s/server/manifests/kube-vip.yaml
    permissions: "0644"
    content: |
      ${indent(6, kube_vip_manifest)}
%{ endif ~}
```

et passer son contenu au template dans `terraform/cloud-init.tf` :

```hcl
kube_vip_manifest = file("${path.module}/cloud-init/kube-vip.yaml")
```

### 13.4 Changer le rôle des deux agents

Dans le bloc `locals` de `terraform/cloud-init.tf`, faire passer `worker_1` et `worker_2` de `agent` à `server`, et les faire rejoindre la **VIP** plutôt que l'IP du premier nœud :

```hcl
locals {
  k3s_bootstrap = {
    control_plane = {
      install_exec = "server"
      config       = "cluster-init: true"
    }
    worker_1 = {
      install_exec = "server"
      config       = "server: https://192.168.1.99:6443"
    }
    worker_2 = {
      install_exec = "server"
      config       = "server: https://192.168.1.99:6443"
    }
  }
}
```

`control_plane` garde `cluster-init: true` : c'est lui qui initialise l'etcd. Les deux autres le rejoignent via la VIP.

### 13.5 Recréer les nœuds un par un pour garder le quorum

Un nœud `agent` ne se « promeut » pas en `server` sur place : il faut le recréer. Le faire **un à la fois**, en attendant que chaque nouveau serveur soit `Ready` avant de passer au suivant, pour ne jamais casser le quorum etcd.

```bash
# 1. Appliquer les changements de config (VIP, tls-san, kube-vip, rôles)
tofu apply

# 2. Recréer le premier ex-agent en serveur
tofu apply -replace='proxmox_virtual_environment_vm.k3s["worker_1"]'
# attendre qu'il soit Ready et membre de l'etcd
kubectl get nodes
kubectl get --raw='/readyz?verbose'

# 3. Puis le second
tofu apply -replace='proxmox_virtual_environment_vm.k3s["worker_2"]'
kubectl get nodes
```

> Ne jamais recréer les deux en même temps : à un instant donné, il faut au moins deux serveurs etcd vivants pour conserver le quorum.

### 13.6 Basculer kubectl et les agents sur la VIP

Dans le `kubeconfig` local, remplacer l'adresse du serveur par la VIP :

```bash
kubectl config set-cluster default --server=https://192.168.1.99:6443
kubectl get nodes
```

Le résultat doit lister **trois** nœuds `server`, tous `Ready`, avec le rôle `control-plane,etcd,master`.

### 13.7 Sauvegarder l'etcd hors du cluster

Trois serveurs protègent de la perte d'**une** VM. Il reste à couvrir la perte des trois (ou une corruption de l'etcd).

k3s prend **déjà** des snapshots etcd automatiques sur le disque local de chaque serveur :

```text
/var/lib/rancher/k3s/server/db/snapshots/   (toutes les 12h par défaut, rétention 5)
```

Ces snapshots locaux dépannent en cas de corruption, mais **disparaissent avec la VM** : un `tofu apply -replace` efface le disque, donc les snapshots. Il faut donc une copie **hors de la VM**. Deux approches simples, à combiner :

1. **Backup Proxmox des trois VMs** (déjà prévu à l'étape 12). Le backup capture le disque entier, snapshots etcd inclus. Restaurer la VM depuis Proxmox = etcd intact, sans rien re-sceller. C'est le plus simple pour ce homelab.

2. **Snapshots vers un stockage objet externe** (facultatif, pour une copie indépendante de Proxmox). Ajouter au `config.yaml` des serveurs (via le template Cloud-Init) :

   ```yaml
   etcd-snapshot-schedule-cron: "0 */6 * * *"
   etcd-snapshot-retention: 20
   etcd-s3: true
   etcd-s3-endpoint: "s3.exemple.com:9000"
   etcd-s3-bucket: "etcd-snapshots"
   etcd-s3-access-key: "<clé>"
   etcd-s3-secret-key: "<secret>"
   ```

> **Ne pas viser le MinIO in-cluster** (étape 8.2) comme destination des snapshots etcd : si le cluster meurt, MinIO meurt avec, et le snapshot devient inaccessible au moment précis où il faudrait le lire. MinIO in-cluster est fait pour les sauvegardes de bases de données, pas pour la reprise etcd. Pour l'option 2, utiliser un S3/MinIO **externe** au cluster.
>
> Les clés d'accès sont des secrets : les gérer via Sealed Secrets ou un fichier local protégé, jamais en clair dans Git. Pour restaurer après une perte totale : restaurer un snapshot sur un serveur, puis rattacher les autres.

### Validation

1. **Trois serveurs `Ready`** : `kubectl get nodes` montre trois nœuds `control-plane,etcd,master`.
2. **Tolérance de panne** : éteindre un des trois serveurs. `kubectl` doit continuer de répondre (via la VIP), et les pods du nœud éteint se replanifient sur les deux autres.
3. **VIP mobile** : vérifier que la VIP répond toujours après l'extinction, portée par un serveur survivant.
4. **Snapshot etcd** : confirmer qu'un snapshot apparaît dans `/var/lib/rancher/k3s/server/db/snapshots/`, et qu'une copie hors VM existe (backup Proxmox ou S3 externe).
