# Déployer une nouvelle application avec PostgreSQL

Ce guide décrit le modèle GitOps validé avec `bot-maison` : un namespace dédié,
une image privée GHCR, des secrets scellés, un ConfigMap, une base PostgreSQL
CloudNativePG sur Longhorn et des sauvegardes dans Garage.

Les exemples utilisent :

- application et namespace : `mon-app` ;
- cluster PostgreSQL : `mon-app-db` ;
- base et utilisateur PostgreSQL : `mon_app` ;
- bucket Garage existant : `db-backups`.

Remplacer ces valeurs pour chaque nouvelle application.

## 1. Prérequis

Avant de commencer, vérifier les briques communes :

```bash
kubectl get applications -n argocd
kubectl get storageclass longhorn
kubectl get deployment -n cnpg-system cloudnative-pg
kubectl get pod -n garage
```

Les applications Argo CD `root`, `longhorn`, `cloudnative-pg` et `garage`
doivent être `Synced/Healthy`. Le bucket et la clé Garage doivent déjà exister ;
voir [garage-bootstrap.md](garage-bootstrap.md).

Le dépôt est lu récursivement par l'application Argo CD `root`. Tous les
manifests de la nouvelle application vont donc dans :

```text
kubernetes/apps/mon-app/
├── namespace.yaml
├── configmap.yaml
├── database.yaml
├── scheduled-backup.yaml
├── deployment.yaml
├── app-secret-sealed.yaml
├── ghcr-login-sealed.yaml
└── garage-app-creds-sealed.yaml
```

Ne jamais commiter un `Secret` en clair, un token, un mot de passe ou un fichier
`.dockerconfigjson`.

## 2. Créer le namespace en premier

Créer `kubernetes/apps/mon-app/namespace.yaml` :

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mon-app
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

La sync wave `-1` force Argo CD à créer le namespace avant les ressources qui
l'utilisent. Sans ce fichier, la synchronisation échoue avec :

```text
namespaces "mon-app" not found
```

Toutes les ressources et tous les secrets décrits ci-dessous doivent utiliser
le même namespace.

## 3. Déclarer la configuration non sensible

Créer `kubernetes/apps/mon-app/configmap.yaml` :

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mon-app-config
  namespace: mon-app
data:
  POSTGRES_HOST: mon-app-db-rw
  POSTGRES_PORT: "5432"
  POSTGRES_DB: mon_app
  LOG_LEVEL: info
```

CloudNativePG crée automatiquement trois Services :

- `mon-app-db-rw` : primaire, pour les écritures et l'usage normal ;
- `mon-app-db-ro` : réplicas en lecture seule, utile avec plusieurs instances ;
- `mon-app-db-r` : toutes les instances disponibles.

Dans le même namespace, le nom court `mon-app-db-rw` suffit.

## 4. Créer les secrets propres au namespace

Les SealedSecrets en mode strict sont liés à leur **nom et namespace**. Copier
un bloc `encryptedData` depuis `default`, puis changer seulement le namespace,
ne fonctionne pas : il faut re-sceller la valeur pour `mon-app`.

### Secret applicatif

Exemple avec une clé API :

```bash
export APP_TOKEN='remplacer-par-le-token'

kubectl create secret generic mon-app-secret \
  --namespace mon-app \
  --from-literal=APP_TOKEN="$APP_TOKEN" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml \
  > kubernetes/apps/mon-app/app-secret-sealed.yaml

unset APP_TOKEN
```

Le fichier obtenu est un `SealedSecret` et peut être commité. Vérifier qu'il
contient deux fois `namespace: mon-app` : dans `metadata` et
`spec.template.metadata`.

### Accès à une image privée GHCR

Créer un PAT GitHub ayant uniquement le droit `read:packages`, puis :

```bash
export GHCR_TOKEN='remplacer-par-le-pat'

kubectl create secret docker-registry ghcr-login-secret \
  --namespace mon-app \
  --docker-server=ghcr.io \
  --docker-username=ArthurBr02 \
  --docker-password="$GHCR_TOKEN" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml \
  > kubernetes/apps/mon-app/ghcr-login-sealed.yaml

unset GHCR_TOKEN
```

### Accès de CloudNativePG à Garage

La région `garage` est obligatoire. Sans elle, le client S3 signe ses requêtes
avec `us-east-1` et Garage répond `400 Bad Request`.

```bash
export GARAGE_ACCESS_KEY_ID='remplacer-par-la-key-id'
export GARAGE_SECRET_ACCESS_KEY='remplacer-par-la-secret-key'

kubectl create secret generic garage-app-creds \
  --namespace mon-app \
  --from-literal=ACCESS_KEY_ID="$GARAGE_ACCESS_KEY_ID" \
  --from-literal=ACCESS_SECRET_KEY="$GARAGE_SECRET_ACCESS_KEY" \
  --from-literal=AWS_REGION=garage \
  --dry-run=client -o yaml \
  | kubeseal --format yaml \
  > kubernetes/apps/mon-app/garage-app-creds-sealed.yaml

unset GARAGE_ACCESS_KEY_ID GARAGE_SECRET_ACCESS_KEY
```

## 5. Déclarer le cluster PostgreSQL

Créer `kubernetes/apps/mon-app/database.yaml` :

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: mon-app-db
  namespace: mon-app
spec:
  # Commencer avec une instance. Plusieurs instances ne remplacent pas les backups.
  instances: 1

  bootstrap:
    initdb:
      database: mon_app
      owner: mon_app

  storage:
    size: 5Gi
    storageClass: longhorn

  backup:
    barmanObjectStore:
      destinationPath: s3://db-backups/mon-app-db
      endpointURL: http://garage.garage.svc:3900
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
    retentionPolicy: "7d"
```

CloudNativePG crée automatiquement le Secret `mon-app-db-app`. Il contient
notamment `username`, `password`, `host`, `port`, `dbname`, `uri`, `jdbc-uri`
et `pgpass`. Il ne faut donc pas choisir ou stocker le mot de passe PostgreSQL
dans Git.

Pour consulter ponctuellement les identifiants :

```bash
kubectl get secret mon-app-db-app -n mon-app \
  -o jsonpath='{.data.username}' | base64 -d; echo

kubectl get secret mon-app-db-app -n mon-app \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Éviter de copier ces valeurs dans un terminal partagé ou dans l'historique du
shell. Les workloads doivent référencer le Secret directement.

## 6. Planifier les sauvegardes physiques

L'option `backup.barmanObjectStore` active l'archivage continu des WAL. Ajouter
également une sauvegarde physique planifiée dans
`kubernetes/apps/mon-app/scheduled-backup.yaml` :

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: mon-app-db-daily
  namespace: mon-app
spec:
  # Format cron à six champs : seconde, minute, heure, jour, mois, semaine.
  schedule: "0 0 2 * * *"
  backupOwnerReference: self
  method: barmanObjectStore
  cluster:
    name: mon-app-db
```

Cette configuration lance une sauvegarde chaque nuit à 02:00. L'archivage WAL
permet ensuite de restaurer à un instant situé entre deux sauvegardes physiques.

## 7. Déployer l'application

Créer `kubernetes/apps/mon-app/deployment.yaml` :

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mon-app
  namespace: mon-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mon-app
  template:
    metadata:
      labels:
        app: mon-app
    spec:
      imagePullSecrets:
        - name: ghcr-login-secret
      containers:
        - name: mon-app
          image: ghcr.io/arthurbr02/mon-app:1.0.0
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          envFrom:
            - configMapRef:
                name: mon-app-config
          env:
            - name: APP_TOKEN
              valueFrom:
                secretKeyRef:
                  name: mon-app-secret
                  key: APP_TOKEN
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: mon-app-db-app
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mon-app-db-app
                  key: password
```

L'application doit réessayer sa connexion si PostgreSQL n'est pas encore prêt
ou redémarre. Au premier déploiement, un court `ConnectionRefusedError` est
normal pendant la création du PVC et l'initialisation de PostgreSQL ; Kubernetes
relance le conteneur, mais une boucle de retry applicative reste préférable.

### Construire une image multi-architecture

Les nœuds du cluster sont en `linux/amd64`. Depuis un Mac ARM, un simple
`docker build` peut publier uniquement `linux/arm64`. Construire les deux
architectures :

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag ghcr.io/arthurbr02/mon-app:1.0.0 \
  --push .

docker buildx imagetools inspect ghcr.io/arthurbr02/mon-app:1.0.0
```

La sortie doit contenir `linux/amd64`. Sinon Kubernetes produit l'erreur
`no match for platform in manifest`.

## 8. Valider avant de publier

Valider localement le YAML :

```bash
kubectl apply --dry-run=client -f kubernetes/apps/mon-app/
```

Lorsque le namespace existe déjà, une validation serveur est plus complète :

```bash
kubectl apply --dry-run=server -f kubernetes/apps/mon-app/
```

Puis commiter et pousser :

```bash
git add kubernetes/apps/mon-app
git commit -m "deploy mon-app"
git push origin main
```

Argo CD réconcilie automatiquement le dépôt. Ne pas utiliser `kubectl apply`
sans `--dry-run` pour déployer ces fichiers : Git doit rester la source de
vérité.

## 9. Vérifier le déploiement

```bash
kubectl get application root -n argocd
kubectl get namespace mon-app
kubectl get sealedsecret,secret -n mon-app
kubectl get cluster,pod,pvc,service -n mon-app
kubectl logs -n mon-app deployment/mon-app
```

Résultat attendu :

- Argo CD : `Synced/Healthy` ;
- cluster PostgreSQL : `Cluster in healthy state`, `READY=1` ;
- PVC : `Bound`, StorageClass `longhorn` ;
- application : `1/1 Running` ;
- Secrets `mon-app-secret`, `ghcr-login-secret`, `garage-app-creds` et
  `mon-app-db-app` présents.

Tester PostgreSQL depuis son pod :

```bash
kubectl exec -n mon-app mon-app-db-1 -- \
  psql -U postgres -d mon_app -c 'SELECT current_database(), current_user;'
```

Tester l'archivage WAL :

```bash
kubectl exec -n mon-app mon-app-db-1 -- \
  psql -U postgres -d postgres -c 'SELECT pg_switch_wal();'

kubectl exec -n mon-app mon-app-db-1 -- \
  psql -U postgres -d postgres -x -c \
  'SELECT archived_count, failed_count, last_archived_wal, last_archived_time FROM pg_stat_archiver;'
```

`archived_count` doit augmenter et `last_archived_time` doit être renseigné.
Vérifier aussi les sauvegardes :

```bash
kubectl get scheduledbackup,backup -n mon-app
kubectl exec -n garage garage-0 -- /garage bucket info db-backups
```

## 10. Erreurs fréquentes

| Symptôme | Cause | Correction |
| --- | --- | --- |
| `namespaces "mon-app" not found` | Namespace absent ou créé trop tard | Ajouter `namespace.yaml` avec la sync wave `-1` |
| SealedSecret créé mais Secret absent | Chiffrement lié à un autre nom/namespace | Re-sceller la valeur avec `--namespace mon-app` |
| `FailedToRetrieveImagePullSecret` | Secret GHCR absent du namespace | Recréer et re-sceller `ghcr-login-secret` dans ce namespace |
| `no match for platform in manifest` | Image publiée seulement pour ARM | Publier au minimum `linux/amd64` avec `buildx` |
| `ConnectionRefusedError` au premier démarrage | PostgreSQL est encore en init | Attendre `READY=1` et prévoir des retries applicatifs |
| Garage répond `400`, scope `us-east-1` | Région S3 absente | Ajouter `AWS_REGION=garage` et le sélecteur `s3Credentials.region` |
| CNPG plante car le CRD `Pooler` manque | CRD trop grand pour le client-side apply | Mettre `ServerSideApply=true` dans l'Application CloudNativePG |
| L'UI Argo affiche encore l'ancien échec | Une ancienne opération est en retry | Terminer l'opération, rafraîchir, puis synchroniser la nouvelle révision |

## 11. Suppression et restauration

Supprimer un `Cluster` CloudNativePG ou son namespace peut supprimer les pods et
PVC associés. Avant toute suppression :

1. vérifier qu'une sauvegarde physique est `completed` ;
2. vérifier que `pg_stat_archiver.archived_count` augmente ;
3. effectuer au moins une restauration de test dans un autre namespace ;
4. ne jamais considérer un backup comme valide tant qu'il n'a pas été restauré.

