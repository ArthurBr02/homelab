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

> Le clonage **complet** des trois VMs en parallèle peut saturer l'API Proxmox et échouer sur le suivi de tâche avec `HTTP 599 Too many redirections` (la VM est alors clonée mais laissée à moitié configurée — arrêtée, RAM du template). Relancer en série : `terraform apply -parallelism=1`. Terraform garde ce qui a réussi et ne finit que le reste.

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
- un **disque persistant** (hors de la VM serveur) conserve l'`etcd` et les données à travers une recréation de VM (voir 8.1).

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

  # Ré-uploade le snippet dès que le contenu généré change (voir piège ci-dessous).
  lifecycle {
    replace_triggered_by = [local_sensitive_file.cloud_init[each.key].id]
  }
}
```

Utiliser impérativement `source_file` avec `upload_mode = "sftp"` lorsque le compte `root` de Proxmox utilise `zsh`. Le mode `stream` transmet le YAML sur l'entrée standard du shell et peut provoquer son exécution accidentelle directement sur l'hôte Proxmox.

> **Piège majeur : le snippet n'est PAS ré-uploadé quand son contenu change.** `proxmox_virtual_environment_file` se repère au **nom de fichier**, pas au hash du contenu. Quand tu modifies le template, Terraform régénère bien le fichier local (`local_sensitive_file` est remplacé) mais **laisse le snippet sur Proxmox tel quel** — `tofu apply` affiche `no changes` sur cette ressource. Un `-replace` de VM rebooterait alors sur l'**ancien** cloud-init, en silence (symptôme vécu : disque persistant jamais monté, `data-dir` absent de `config.yaml`).
>
> Le bloc `lifecycle { replace_triggered_by = [...] }` ci-dessus corrige ça : il force le ré-upload dès que le contenu généré change. Sans ce bloc, forcer à la main après chaque modif de template :
>
> ```bash
> tofu apply -replace='proxmox_virtual_environment_file.cloud_init["control_plane"]'
> ```
>
> Et **toujours vérifier sur l'hôte Proxmox** que le snippet uploadé contient bien tes changements avant de recréer la VM :
>
> ```bash
> grep -nE 'disk_setup|data-dir' /media/storage/snippets/k3s-control-plane-1-cloud-init.yaml
> ```

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

### Prévoir la survie de l'état

Avec un seul serveur et deux agents, Cloud-Init réinstalle automatiquement k3s si la VM est recréée, mais l'`etcd` — donc tout l'état Kubernetes — disparaît avec le disque du serveur. Les agents n'en gardent aucune copie.

Le choix de ce homelab (détaillé en 8.1) : **rester à 1 serveur + 2 agents**, mais placer l'`etcd` et les données Longhorn sur un **disque persistant possédé hors de la VM serveur**. La VM redevient jetable ; le disque, lui, survit à sa recréation, et k3s reprend l'état existant au redémarrage.

> Alternative non retenue : trois nœuds `server` avec etcd embarqué + kube-vip, qui tolèrent la perte d'une VM sans aucune intervention. Plus robuste, mais plus lourd — écarté ici au profit de la simplicité (voir la discussion en 8.1).

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

> Sur un nœud k3s, un `kubectl` autonome peut manquer : k3s embarque le sien. Utiliser `sudo k3s kubectl get nodes`, ou exporter `KUBECONFIG=/etc/rancher/k3s/k3s.yaml` (fichier `root:root 600`, donc via `sudo` ou après l'avoir copié + chowné). k3s crée normalement le lien `/usr/local/bin/kubectl` à l'installation.

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

   > Cet accès est temporaire : il ne dure que le temps où les deux commandes tournent, et rien n'est publié sur le réseau. Il reste la méthode de secours si le reverse proxy ou l'Ingress ne fonctionne plus. L'accès permanent par nom de domaine est décrit ci-dessous.

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
   > - `destination.namespace` : les manifestes sans namespace explicite utilisent cette cible ; sans elle, Argo CD refuse la ressource avec `InvalidSpecError: Namespace ... is missing`.

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

Argo CD et Sealed Secrets réparent la partie « configuration et secrets », mais **pas l'`etcd` ni les données** : ni l'un ni l'autre ne sont dans Git. Reconstruire la VM serveur détruit son disque, donc l'état Kubernetes et les volumes.

La réponse retenue (détaillée en 8.1) : sortir l'`etcd` et les données Longhorn de la VM, sur un **disque persistant possédé hors de son cycle de vie**. Un `tofu apply -replace` du serveur recrée la VM mais **réattache le même disque**, et k3s **reprend l'`etcd` existant** — sans bootstrap, sans perte.

Deux chaînes de récupération, selon ce qui est perdu :

```text
# Cas normal : VM serveur recréée, disque persistant intact
tofu apply -replace serveur
  → Cloud-Init réinstalle k3s (--data-dir sur le disque réattaché)
  → k3s reprend l'etcd existant → Argo CD, secrets, apps : tout revient (0 perte)

# Cas extrême : disque de données perdu (SSD mort)
Terraform recrée la VM (etcd vide)
  → ./kubernetes/bootstrap.sh (Argo CD + Sealed Secrets + app racine)
  → re-sceller les secrets (clé perdue avec le disque)
  → Argo CD resynchronise apps depuis Git
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

Le stockage repose sur une **fondation** — un disque persistant (**8.1**) qui porte l'`etcd` et les données — puis trois couches applicatives, à installer **dans cet ordre** car chacune dépend de la précédente :

1. **Longhorn** (**8.2**) — stockage bloc répliqué. Le stockage par défaut de k3s (`local-path`) attache un volume à un seul nœud ; si ce nœud tombe, le volume devient indisponible. Longhorn réplique les données au niveau bloc, pour que le volume suive le pod.
2. **Garage** (**8.3**) — stockage objet (dans le cluster, sur des volumes Longhorn). Destination des sauvegardes de bases de données.
3. **CloudNativePG** (**8.4**) — opérateur PostgreSQL : réplication, bascule, archivage WAL et restauration à un instant donné, avec sauvegardes vers Garage.

> Tout passe par Argo CD (étape 7). Chaque composant est décrit par une ressource `Application` commitée dans `kubernetes/apps/<composant>/`, que l'app racine déploie automatiquement. On n'installe plus rien avec `helm install` à la main.
>
> Une ressource `Application` vit dans le namespace `argocd` : ses manifestes doivent donc porter `metadata.namespace: argocd` explicitement, sinon l'app racine les enverrait dans `default`.

### 8.1 Le disque persistant du serveur (fondation)

Longhorn **et** l'`etcd` doivent survivre à une recréation de la VM serveur. La fondation commune est un **disque séparé, possédé hors de la VM**, que Terraform ne supprime pas quand il recrée cette VM. La VM devient jetable (*cattle*), le disque de données devient un *pet*.

Distinction clé, souvent source de confusion :

- Le **datastore** `media-storage` (le SSD `sdb`, monté `/media/storage` sur l'hôte Proxmox) persiste toujours.
- Mais le **disque d'une VM** n'est qu'un fichier *dans* ce datastore (`media-storage:vm-9001-disk-0`). Quand Terraform **détruit** la VM, Proxmox **supprime ce fichier**.

D'où deux cas :

- **Coupure de courant / reboot** : la VM n'est pas détruite → son disque reste → k3s redémarre et l'etcd reprend. **Déjà couvert, rien à construire.**
- **`tofu apply -replace`** : la VM est détruite → son fichier-disque est supprimé → perte. C'est le cas que ce disque persistant traite.

```text
media-storage (sdb, persiste toujours)
├── vm-9001-disk-0   OS serveur    → jetable (supprimé au -replace)
├── vm-9900-disk-0   data k3s      → persistant (jamais supprimé)
│     monté /mnt/k3s-data :
│       rancher/k3s  → etcd, certs, token, clé Sealed Secrets
│       longhorn     → volumes PVC (réplica-1)
├── vm-9002-disk-0   OS worker-1   → jetable
└── vm-9003-disk-0   OS worker-2   → jetable
```

> Choix assumés : **copie unique** (pas de redondance ni de backup externe) et **pas de HA** (le serveur reste le point unique du control plane). En échange : simplicité maximale et zéro perte sur les deux cas ci-dessus. La validation `-replace` est en 8.5. Pas de kube-vip : un seul serveur, son IP statique (`192.168.1.100`) reste l'endpoint stable de l'API ; les agents se reconnectent seuls après un rebuild.

**Provisionner le volume (une fois, hors Terraform).** Sur l'hôte Proxmox, allouer un volume avec un **VMID fantôme** qu'aucune VM n'utilise (ni le template `9000`, ni les VMs `9001`–`9003`) :

```bash
# sur l'hôte Proxmox
pvesm alloc media-storage 9900 vm-9900-disk-0.raw 100G --format raw
```

Le volume ainsi créé — son volid exact est visible avec `pvesm list media-storage | grep 9900`, par exemple `media-storage:9900/vm-9900-disk-0.raw` — n'appartient à aucune VM active : Terraform ne le détruira jamais.

**Attacher le disque à la VM serveur (Terraform).** Deux changements dans `terraform/cloned-vm.tf`, **uniquement pour le serveur** :

1. Empêcher Terraform de supprimer les disques qu'il ne gère pas, sur la ressource `proxmox_virtual_environment_vm.k3s` :

   ```hcl
   delete_unreferenced_disks_on_destroy = false
   ```

2. Déclarer les disques. **Dès qu'on ajoute un bloc `disk`, bpg gère la liste complète des disques de la VM** : il faut donc aussi déclarer le disque OS cloné (`scsi0`), sinon bpg tente de le supprimer au prochain apply (`cannot delete boot disk "scsi0"`). On déclare `scsi0` pour **toutes** les VMs, et on n'ajoute `scsi1` (le disque persistant) qu'au `control_plane` :

   ```hcl
   # disque OS cloné — obligatoire, sinon bpg veut le supprimer
   disk {
     datastore_id = var.proxmox_datastore_id
     interface    = "scsi0"
     size         = 20            # taille réelle du disque OS : qm config 9001 | grep scsi0
   }

   # disque de données persistant — serveur uniquement
   dynamic "disk" {
     for_each = each.key == "control_plane" ? [1] : []
     content {
       datastore_id      = var.proxmox_datastore_id
       path_in_datastore = "9900/vm-9900-disk-0.raw"   # format stockage-répertoire
       interface         = "scsi1"
       size              = 100
     }
   }
   ```

> `path_in_datastore` référence un volume **déjà existant** : Terraform l'attache sans le recréer ni le formater. Le volume garde son nom `vm-9900-disk-0` (possédé par le VMID fantôme 9900), condition nécessaire pour survivre à un `-replace`.
>
> **Le format de `path_in_datastore` dépend du type de stockage.** Sur un stockage **répertoire** comme `media-storage`, c'est `<vmid>/<fichier>.<ext>` — récupérer le volid exact avec `pvesm list media-storage | grep 9900`, et prendre tout ce qui suit `media-storage:`. Sur du LVM/bloc, ce serait `vm-9900-disk-0` tout court.
>
> ⚠️ `path_in_datastore` est marqué **expérimental** par `bpg/proxmox` (la demande d'un `prevent_from_destruction` natif a été refusée, « not planned »). Épingler la version du provider dans `terraform/versions.tf`, et **prouver la survie au `-replace`** (8.5) avant d'y confier des données.

**Monter le disque et y placer l'etcd (Cloud-Init).** Dans `terraform/cloud-init/k3s.yaml.tftpl`, uniquement sur le serveur, préparer et monter le disque **de façon idempotente** : il ne faut surtout pas reformater un disque qui contient déjà l'etcd au moment d'un rebuild.

```yaml
%{ if install_exec == "server" ~}
disk_setup:
  /dev/sdb:
    table_type: gpt
    layout: true
    overwrite: false        # ne repartitionne pas un disque déjà initialisé
fs_setup:
  - device: /dev/sdb1
    filesystem: ext4
    overwrite: false        # ne reformate pas si un ext4 existe déjà
mounts:
  - [/dev/sdb1, /mnt/k3s-data, ext4, "defaults,nofail", "0", "2"]
%{ endif ~}
```

Puis pointer le data-dir de k3s sur ce disque, dans le `config.yaml` généré :

```yaml
write_files:
  - path: /etc/rancher/k3s/config.yaml
    permissions: "0600"
    content: |
      token: ${jsonencode(k3s_token)}
%{ if install_exec == "server" ~}
      data-dir: /mnt/k3s-data/rancher/k3s
%{ endif ~}
      ${indent(6, k3s_config)}
```

`data-dir` est conditionné au serveur : `/mnt/k3s-data` n'est monté que là. Sur un worker (agent), on garde le data-dir par défaut.

> Comportement selon l'état du disque :
> - **Premier boot** (disque vierge) : `fs_setup` formate, k3s `cluster-init: true` crée un etcd neuf.
> - **Rebuild** (disque déjà rempli) : `overwrite: false` ne touche à rien, k3s trouve l'etcd existant sur `/mnt/k3s-data` et **le reprend**. `cluster-init: true` est ignoré sur un etcd existant.
>
> Vérifier le nom réel du disque (`/dev/sdb` vs `/dev/vdb`) avec `lsblk` : `scsi1` donne `sd*`, un contrôleur `virtio` donnerait `vd*`.
>
> Ordonnancement : sur une construction **neuve**, intégrer ces changements Cloud-Init dès l'étape 4 (à la création des VMs). Sur le cluster **existant**, les appliquer ici en recréant la VM serveur (le bot n'a pas encore de données critiques).
>
> Après toute modif du template, **vérifier que le snippet a bien été ré-uploadé à Proxmox avant de recréer la VM** (voir le piège du snippet à l'étape 4). Sans le `replace_triggered_by`, le `-replace` rebooterait sur l'ancien cloud-init et le disque ne serait pas monté.

### 8.2 Longhorn (stockage bloc répliqué)

**Prérequis système, dans Cloud-Init.** Longhorn a besoin de `open-iscsi` et `nfs-common` sur chaque nœud. Les ajouter au bloc `packages` de `terraform/cloud-init/k3s.yaml.tftpl` :

```yaml
packages:
  - curl
  - open-iscsi
  - nfs-common
```

**Données Longhorn sur le disque du serveur.** Longhorn stocke ses volumes dans le sous-dossier `longhorn/` du disque persistant de 8.1 (`defaultDataPath: /mnt/k3s-data/longhorn`), en **une seule copie sur le serveur**. Les deux workers n'ont pas de disque persistant : on y **désactive le scheduling Longhorn** (UI Longhorn → réglages de nœud → *Scheduling Disabled* sur les disques des workers), pour que l'unique réplica atterrisse sur le serveur. Un pod qui tourne sur un worker accède quand même au volume, servi par le réseau depuis le serveur.

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
          defaultClassReplicaCount: 1   # copie unique, sur le serveur (voir 8.2)
        defaultSettings:
          defaultDataPath: /mnt/k3s-data/longhorn
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
> `defaultClassReplicaCount: 1` = une seule copie, épinglée au serveur (workers en *Scheduling Disabled*, voir plus haut). Copie unique assumée : pas de backup externe.

### 8.3 Garage (stockage objet, dans le cluster)

Déployé dans le cluster, sur des volumes Longhorn. Sert de destination aux sauvegardes de bases de données. L'`etcd`, lui, n'est pas sauvegardé ici : il vit sur le disque persistant du serveur (8.1).

Garage (Deuxfleurs) remplace MinIO : l'édition open-source de MinIO a été vidée de sa console d'admin en 2025 et pousse vers le produit commercial AIStor, sous AGPL. Garage est S3-compatible, léger, pensé pour le self-host, sous licence Apache 2.0.

**Manifests bruts, pas de chart.** Contrairement à MinIO (chart Helm), Garage est décrit en **manifests kustomize**. Contrainte GitOps : le root-app fait `directory.recurse: true` sur `kubernetes/apps`, donc des manifests bruts posés là seraient rendus dans l'app racine (namespace `default`). Les manifests Garage vivent donc dans **`kubernetes/garage/`** (hors du recurse), ciblés par une `Application` placée dans `kubernetes/apps/garage/`.

**Secret racine via Sealed Secrets.** Garage a besoin d'un `rpc_secret` (auth interne du cluster Garage) et d'un `admin_token`. Les générer et sceller (même méthode qu'à l'étape 7) — injectés en variables d'environnement `GARAGE_RPC_SECRET` / `GARAGE_ADMIN_TOKEN`, ils surchargent le `garage.toml`, donc aucun secret n'est en clair dans le ConfigMap :

```bash
RPC=$(openssl rand -hex 32)
ADMIN=$(openssl rand -base64 32)
kubectl create secret generic garage-secrets \
  --namespace garage \
  --from-literal=GARAGE_RPC_SECRET="$RPC" \
  --from-literal=GARAGE_ADMIN_TOKEN="$ADMIN" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml \
  > kubernetes/garage/garage-secrets-sealed.yaml
```

**Manifests kustomize** dans `kubernetes/garage/` :

- `configmap-garage-toml.yaml` — le `garage.toml` (sans secrets) : `replication_factor = 1`, `db_engine = "sqlite"`, `[s3_api]` (`s3_region = "garage"`, port 3900), `[admin]` (port 3903) ;
- `statefulset.yaml` — image `dxflrs/garage:v2.3.0`, `envFrom` le secret scellé, **2 PVC Longhorn** : `meta` (1Gi) et `data` (20Gi) ;
- `service.yaml` — ClusterIP nommé `garage`, ports 3900 (S3) et 3903 (admin) → DNS stable `garage.garage.svc:3900` ;
- `kustomization.yaml` — liste les quatre ressources ci-dessus + le SealedSecret.

**Déploiement via Argo CD.** Créer `kubernetes/apps/garage/application.yml` pointant sur les manifests :

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: garage
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/arthurbr02/homelab.git
    targetRevision: main
    path: kubernetes/garage        # manifests hors de apps/ (recurse du root-app)
  destination:
    server: https://kubernetes.default.svc
    namespace: garage
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Commiter d'abord `garage-secrets-sealed.yaml`, puis le reste, pour que le secret existe quand le pod démarre.

**Amorçage manuel (non déclaratif).** Après le premier sync, Garage n'est pas encore utilisable : il faut assigner un **layout** (obligatoire même sur un seul nœud), puis créer le **bucket** `db-backups`, une **clé d'accès** et son autorisation. Procédure complète dans `docs/garage-bootstrap.md`. En résumé :

```bash
kubectl exec -n garage garage-0 -- /garage status         # relève le node_id
kubectl exec -n garage garage-0 -- /garage layout assign -z dc1 -c 20G <node_id_prefix>
kubectl exec -n garage garage-0 -- /garage layout apply --version 1
kubectl exec -n garage garage-0 -- /garage bucket create db-backups
kubectl exec -n garage garage-0 -- /garage key create backups-key    # affiche Key ID + Secret
kubectl exec -n garage garage-0 -- /garage bucket allow --read --write db-backups --key backups-key
```

La clé générée (Key ID + secret) est ensuite scellée dans le namespace de l'app qui sauvegarde (voir 8.4).

> `replication_factor = 1` = une seule copie. Suffisant pour des sauvegardes de homelab. Augmenter (et ajouter des nœuds Garage) plus tard si le besoin de résilience objet apparaît.

### 8.4 CloudNativePG (PostgreSQL géré)

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
      # Les CRD CloudNativePG dépassent la limite des annotations du
      # client-side apply.
      - ServerSideApply=true
```

**Définir une base par application.** L'opérateur installé, une base se décrit par une ressource `Cluster`, placée dans le dossier de l'application concernée (une base par app, elles évoluent ensemble). Exemple type, avec sauvegarde vers Garage :

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
      endpointURL: http://garage.garage.svc:3900   # path-style S3 garanti par l'endpoint explicite
      s3Credentials:
        accessKeyId:
          name: garage-app-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: garage-app-creds
          key: ACCESS_SECRET_KEY
        region:
          name: garage-app-creds
          key: AWS_REGION
    retentionPolicy: "30d"
```

> Les identifiants d'accès Garage (`garage-app-creds`) sont un secret : le sceller avec `kubeseal` et le commiter, comme les autres. Il doit contenir `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY` et `AWS_REGION=garage`. La clé provient de l'amorçage Garage (8.3, `garage key create`). `instances: 1` au départ ; passer à `2` seulement après avoir validé Longhorn et équipé les nœuds (étape 12).

### 8.5 Valider

**Stockage :**

1. **StorageClass par défaut** : `kubectl get storageclass` montre `longhorn (default)` et `local-path` sans le tag `(default)`.
2. **Volume répliqué** : créer un PVC de test, écrire un fichier, supprimer le pod, le recréer sur un autre nœud, vérifier que le fichier est toujours là.
3. **Cycle sauvegarde/restauration PostgreSQL** :
   1. Créer une base de test avec `instances: 1`.
   2. Y insérer des données.
   3. La détruire.
   4. La restaurer depuis la sauvegarde Garage.

> Tant que cette restauration n'a pas fonctionné, ne migre aucune donnée réelle.

**Survie du disque persistant** — procédure de validation (à rejouer avant toute donnée réelle, `path_in_datastore` étant expérimental) :

1. Poser deux témoins : `kubectl create configmap survivor --from-literal=proof=avant-replace`, plus un PVC Longhorn contenant un fichier connu.
2. Recréer la VM serveur : `tofu apply -replace='proxmox_virtual_environment_vm.k3s["control_plane"]'`.
3. Après redémarrage, vérifier que **rien n'a été perdu** :
   - `vm-9900-disk-0` existe toujours (Proxmox → media-storage) ;
   - le témoin etcd : `kubectl get configmap survivor -o jsonpath='{.data.proof}'` ;
   - Argo CD + Sealed Secrets présents, secrets déchiffrés ;
   - le fichier du PVC Longhorn intact ;
   - les deux agents reconnectés : `kubectl get nodes` → 3 `Ready`.

> **Reprise en place validée en pratique** : le volume `vm-9900-disk-0` survit à un `-replace` **et** à un `terraform destroy` complet (possédé par le VMID fantôme 9900, `delete_unreferenced_disks_on_destroy = false`), et k3s reprend l'etcd depuis le disque. Le nœud serveur garde même son ancienneté (`AGE`) après recréation, preuve que l'etcd est repris et non réinitialisé.
>
> **From-scratch : les workers ne se ré-enregistrent pas seuls.** Quand le serveur repart sur un etcd **neuf** (disque vierge ou wipé), il génère une **nouvelle CA TLS** ; les agents ont l'ancienne en cache et échouent (`x509: certificate signed by unknown authority`). Il faut les recréer — ils sont du cattle : `tofu apply -replace='proxmox_virtual_environment_vm.k3s["worker_1"]' -replace='...worker_2'` (ou wiper `/var/lib/rancher/k3s/agent` sur chacun). Dans le cas **normal** (reprise en place, etcd + CA préservés sur le disque), les workers se reconnectent **tout seuls**.

> **Cas particulier — perte du disque de données** (SSD mort ou volume supprimé) : le cluster repart à vide. Rejouer `kubernetes/bootstrap.sh` (étape 7), puis **re-sceller** les secrets — la clé Sealed Secrets vivait dans l'etcd sur le disque perdu (copie unique assumée). Tant que le disque survit, un `-replace` reprend seul, sans bootstrap.
>
> **Repli si `path_in_datastore` déçoit** : garder le disque **dans** la VM serveur et ne jamais faire `-replace` dessus — le serveur devient un *pet*, la reprise après coupure reste automatique, seul un rebuild OS from-scratch redevient manuel (détacher → recréer → rattacher).

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
   - Utiliser une seule instance dans un premier temps, avec une sauvegarde vers Garage.
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
- Déplacer le fichier d'état Terraform vers un backend distant (S3 ou Garage).
- Configurer les sauvegardes Proxmox des trois VMs du cluster.

> Le disque de données persistant (`vm-9900-disk-0`, voir 8.1) est **attaché** à la VM serveur (`scsi1`, `backup=1`) : un backup Proxmox de la VM serveur **le capture donc**. C'est un filet gratuit contre le « SSD mort = perte totale » — à condition que la destination de backup soit sur un **autre support physique** que `media-storage`, sinon la panne du SSD emporterait aussi la sauvegarde.

### Vérification finale

Le dépôt Git décrit-il toute l'infrastructure ?

```text
Machine morte → Terraform recrée la VM → Cloud-Init réinstalle k3s → le nœud rejoint le cluster → Argo CD redéploie le reste
```

## 13. Ajouter les interfaces d’administration

Cette étape est volontairement placée à la fin : les interfaces ne doivent être
ajoutées qu’après validation du cluster, du stockage et des sauvegardes.

### 13.1 Exposer Argo CD sur `argocd.arthurbratigny.fr`

Le chemin réseau retenu est :

```text
Internet → Nginx Proxy Manager (TLS) → 192.168.1.100:80
         → Traefik → Service argocd-server:80
```

Nginx Proxy Manager termine TLS. Argo CD sert donc HTTP à l'intérieur du réseau
de confiance ; il ne faut jamais publier directement le port 80 de Traefik sur
Internet.

Créer `kubernetes/apps/argocd-access/config.yaml` :

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-cm
    app.kubernetes.io/part-of: argocd
data:
  url: https://argocd.arthurbratigny.fr
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-cmd-params-cm
    app.kubernetes.io/part-of: argocd
data:
  server.insecure: "true"
```

Créer `kubernetes/apps/argocd-access/ingress.yaml` :

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: traefik
  rules:
    - host: argocd.arthurbratigny.fr
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  name: http
```

Après le premier sync de `server.insecure`, redémarrer une fois le serveur pour
qu'il relise le paramètre :

```bash
sudo kubectl rollout restart deployment argocd-server -n argocd
sudo kubectl rollout status deployment argocd-server -n argocd
```

Dans le DNS public, créer un enregistrement `argocd.arthurbratigny.fr` pointant
vers l'adresse publique qui arrive sur Nginx Proxy Manager. Dans Nginx Proxy
Manager, créer un **Proxy Host** :

- Domain Names : `argocd.arthurbratigny.fr` ;
- Scheme : `http` ;
- Forward Hostname/IP : `192.168.1.100` ;
- Forward Port : `80` ;
- Websockets Support : activé ;
- Block Common Exploits : activé ;
- certificat Let's Encrypt, `Force SSL` et HTTP/2 activés.

Si le routeur ne supporte pas le NAT loopback, ajouter aussi une entrée DNS
locale qui résout `argocd.arthurbratigny.fr` vers l'adresse LAN de Nginx Proxy
Manager. Le nom et le certificat restent identiques à l'intérieur et à
l'extérieur du réseau.

Le proxy doit conserver le header `Host`, ce que Nginx Proxy Manager fait par
défaut : Traefik s'en sert pour sélectionner l'Ingress.

Valider depuis le réseau local avant d'ouvrir le NAT :

```bash
curl -I -H 'Host: argocd.arthurbratigny.fr' http://192.168.1.100
```

Puis ouvrir `https://argocd.arthurbratigny.fr`. Pour le CLI derrière ce reverse
proxy HTTP, utiliser le mode gRPC-Web :

```bash
argocd login argocd.arthurbratigny.fr --grpc-web
argocd app list --grpc-web
```

> Argo CD est une interface d'administration critique. Préférer un accès par
> VPN ou une Access List Nginx Proxy Manager. Si elle est accessible depuis
> Internet, conserver TLS, un mot de passe unique, supprimer le secret admin
> initial et configurer ensuite un SSO/MFA. Ne pas ajouter de cache CDN devant
> Argo CD.

### 13.2 Administrer PostgreSQL et Garage

Les interfaces d'administration ne doivent pas être nécessaires au
fonctionnement des services. Les garder en `ClusterIP` et commencer par un
`sudo kubectl port-forward`. Une exposition permanente doit passer par Traefik,
Nginx Proxy Manager, TLS et une restriction d'accès.

#### PostgreSQL depuis DataGrip (recommandé)

CloudNativePG ne publie pas PostgreSQL hors du cluster. Ouvrir un tunnel local
vers le Service primaire de la base voulue :

```bash
sudo kubectl port-forward -n bot-maison svc/bot-maison-db-rw 15432:5432
```

Configurer une source PostgreSQL dans DataGrip :

- Host : `127.0.0.1` ;
- Port : `15432` ;
- Database : `veille` ;
- User : valeur `username` du Secret `bot-maison-db-app` ;
- Password : valeur `password` du même Secret.

Lire ponctuellement les identifiants :

```bash
sudo kubectl get secret bot-maison-db-app -n bot-maison \
  -o jsonpath='{.data.username}' | base64 -d; echo

sudo kubectl get secret bot-maison-db-app -n bot-maison \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Le port n'existe que sur la machine qui exécute `sudo kubectl port-forward` et se
ferme avec `Ctrl+C`. Ne jamais créer un Service `NodePort` ou `LoadBalancer`
pour PostgreSQL uniquement afin d'utiliser DataGrip.

#### PostgreSQL dans le navigateur avec Adminer (optionnel)

Adminer est utile pour une consultation ponctuelle depuis un navigateur. Créer
`kubernetes/apps/adminer/resources.yaml` :

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: admin-tools
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: adminer
  namespace: admin-tools
spec:
  replicas: 1
  selector:
    matchLabels:
      app: adminer
  template:
    metadata:
      labels:
        app: adminer
    spec:
      containers:
        - name: adminer
          image: adminer:5.4.1-standalone
          env:
            - name: ADMINER_DEFAULT_SERVER
              value: bot-maison-db-rw.bot-maison.svc.cluster.local
          ports:
            - name: http
              containerPort: 8080
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              cpu: 250m
              memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: adminer
  namespace: admin-tools
spec:
  selector:
    app: adminer
  ports:
    - name: http
      port: 8080
      targetPort: http
```

Accéder à l'UI sans l'exposer :

```bash
sudo kubectl port-forward -n admin-tools svc/adminer 8081:8080
```

Ouvrir `http://localhost:8081`, choisir PostgreSQL et utiliser les identifiants
CloudNativePG. Pour une autre base, saisir son DNS complet
`<cluster>-rw.<namespace>.svc.cluster.local`.

Pour une UI permanente, ajouter un Ingress vers ce Service :

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: adminer
  namespace: admin-tools
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: traefik
  rules:
    - host: db.arthurbratigny.fr
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: adminer
                port:
                  name: http
```

Créer ensuite `db.arthurbratigny.fr` dans le DNS et un Proxy Host Nginx Proxy
Manager vers `http://192.168.1.100:80`, comme pour Argo CD. Une Access List ou
un VPN est obligatoire pour ce domaine.

> Adminer permet d'exécuter du SQL et de supprimer des données. Ne pas le rendre
> public sans authentification supplémentaire au niveau de Nginx Proxy Manager,
> et idéalement le laisser accessible uniquement par VPN/port-forward.

#### Parcourir les fichiers Garage avec Garage Web UI

[Garage Web UI](https://github.com/khairul169/garage-webui) est un projet tiers
qui affiche l'état du cluster, les buckets, les clés et les objets. Il utilise
l'API d'administration Garage : son accès équivaut donc à un accès administrateur
complet.

Créer d'abord un mot de passe HTTP distinct et le sceller :

```bash
export GARAGE_UI_PASSWORD='remplacer-par-un-mot-de-passe-fort'
GARAGE_UI_HASH=$(htpasswd -nbBC 12 garage "$GARAGE_UI_PASSWORD" | cut -d: -f2-)

sudo kubectl create secret generic garage-webui-auth \
  --namespace garage \
  --from-literal=AUTH_USER_PASS="garage:$GARAGE_UI_HASH" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml \
  > kubernetes/garage/garage-webui-auth-sealed.yaml

unset GARAGE_UI_PASSWORD GARAGE_UI_HASH
```

Ajouter le SealedSecret à `kubernetes/garage/kustomization.yaml`, puis créer
`kubernetes/garage/garage-webui.yaml` :

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: garage-webui
  namespace: garage
spec:
  replicas: 1
  selector:
    matchLabels:
      app: garage-webui
  template:
    metadata:
      labels:
        app: garage-webui
    spec:
      containers:
        - name: garage-webui
          image: khairul169/garage-webui:1.1.0
          env:
            - name: API_BASE_URL
              value: http://garage:3903
            - name: API_ADMIN_KEY
              valueFrom:
                secretKeyRef:
                  name: garage-secrets
                  key: GARAGE_ADMIN_TOKEN
            - name: S3_ENDPOINT_URL
              value: http://garage:3900
            - name: S3_REGION
              value: garage
            - name: AUTH_USER_PASS
              valueFrom:
                secretKeyRef:
                  name: garage-webui-auth
                  key: AUTH_USER_PASS
          ports:
            - name: http
              containerPort: 3909
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              cpu: 250m
              memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: garage-webui
  namespace: garage
spec:
  selector:
    app: garage-webui
  ports:
    - name: http
      port: 3909
      targetPort: http
```

Ajouter aussi `garage-webui.yaml` aux ressources du `kustomization.yaml`, puis :

```bash
sudo kubectl port-forward -n garage svc/garage-webui 3909:3909
```

Ouvrir `http://localhost:3909` et se connecter avec l'utilisateur `garage` et
le mot de passe choisi. L'onglet de navigation des objets permet de voir,
télécharger et gérer les fichiers des buckets.

> Ne pas exposer directement cette UI sur Internet : elle détient
> `GARAGE_ADMIN_TOKEN`. Si un accès permanent est indispensable, créer un
> Ingress dédié et appliquer le même chemin Traefik → Nginx Proxy Manager que
> pour Argo CD, avec TLS **et** une Access List/VPN.
