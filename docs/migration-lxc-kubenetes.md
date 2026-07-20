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

## 4. Monter le cluster

- Installer k3s sur la cheffe.
- Rattacher les deux ouvrières, avec une commande sur chacune.
- Vérifier l'état des nœuds :

  ```bash
  kubectl get nodes
  ```

  Le résultat doit contenir trois lignes avec l'état `Ready`.

## 5. Faire un premier test manuel

- Mettre un bot du LXC 108 dans une image Docker.
- Créer `kubernetes/apps/bot-x/deployment.yaml`. Un bot n'a besoin que de ce fichier.
- Faire un commit et un push.
- Déployer et vérifier que le bot répond sur Discord :

  ```bash
  kubectl apply -f kubernetes/apps/bot-x/deployment.yaml
  ```

- Éteindre volontairement une ouvrière : le bot doit redémarrer seul sur l'autre.

## 6. Passer en pilote automatique

- Installer Argo CD dans le cluster et le relier au dépôt Git. Son rôle est de garder le cluster identique à ce que Git décrit.
- Installer Sealed Secrets afin de chiffrer les tokens Discord et les mots de passe avant de les commiter.
- Confier à Argo CD le bot créé à l'étape précédente.

### Validation

Modifier le YAML du bot, pousser le changement et vérifier qu'Argo CD le déploie sans utiliser `kubectl`.

Désormais, le geste quotidien est :

```text
modifier → commit → push
```

## 7. Préparer le stockage des données

- Installer **Longhorn**. Le stockage par défaut de k3s (`local-path`) attache un volume à son nœud ; si le worker tombe, le volume devient indisponible. Longhorn réplique les données au niveau bloc afin que le volume puisse suivre le pod.
- Installer **MinIO**, ou utiliser un stockage objet existant. Il servira de destination aux sauvegardes des bases de données.
- Installer l'opérateur **CloudNativePG**. Il gérera PostgreSQL : réplication, bascule, archivage WAL et restauration à un instant donné.

> Ne jamais créer manuellement un `StatefulSet` PostgreSQL.

### Validation

1. Créer une base de test avec `instances: 1`.
2. Y insérer des données.
3. La détruire.
4. La restaurer depuis une sauvegarde.

> Tant que cette restauration n'a pas fonctionné, ne migrer aucune donnée réelle.

## 8. Migrer les services

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

## 9. Augmenter la RAM progressivement

Après chaque LXC éteint :

1. Vérifier la mémoire disponible avec `free -h`.
2. Augmenter la variable de RAM dans le fichier Terraform.
3. Exécuter `terraform apply`.
4. Redémarrer la VM concernée.
5. Créer un commit pour ce palier afin que l'historique montre la croissance du cluster.

**Cible finale :**

- 8 Go par ouvrière ;
- 4 Go pour la cheffe.

## 10. Services qui ne migrent pas

Les services suivants restent dans des LXC :

| LXC | Service |
| ---: | --- |
| 116 | Pi-hole |
| 111 | Proxy |
| 102 | VPN |
| 101 | Ansible |
| 109 | Service Manager |

Ils constituent le socle de l'infrastructure. Si le DNS, le reverse proxy ou les outils d'administration étaient hébergés dans le cluster, une panne du cluster pourrait supprimer les moyens nécessaires à sa réparation.

## 11. Finaliser

- Passer les bases de données à `instances: 2`, une fois Longhorn opérationnel et les workers équipés de 8 Go de RAM.
- Effectuer un test réel de bascule : arrêter le nœud qui héberge le primaire PostgreSQL et chronométrer la reprise.
- Déplacer le fichier d'état Terraform vers un backend distant (S3 ou MinIO).
- Configurer les sauvegardes Proxmox des trois VMs du cluster.

### Vérification finale

Le dépôt Git décrit-il toute l'infrastructure ?

```text
Machine morte → terraform apply recrée les VMs → Argo CD redéploie le reste
```
