# Amorçage de Garage

Garage ne s'amorce pas tout seul : après le premier déploiement, il faut
**assigner un layout** (obligatoire même sur un seul nœud), puis créer le
**bucket** et la **clé d'accès**. Ces étapes ne sont pas déclaratives — on les
lance une fois à la main via `kubectl exec`.

Prérequis : l'`Application` ArgoCD `garage` est `Synced/Healthy` et le pod
`garage-0` est `Running` (`kubectl get pod -n garage`).

## 1. Assigner le layout

Le `node_id` n'est connu qu'au runtime : on le lit d'abord.

```bash
# Affiche le node_id (colonne "ID", on garde un préfixe suffisant pour être unique)
kubectl exec -n garage garage-0 -- /garage status

# Assigner le nœud à une zone avec une capacité, puis appliquer
kubectl exec -n garage garage-0 -- /garage layout assign -z dc1 -c 20G <node_id_prefix>
kubectl exec -n garage garage-0 -- /garage layout apply --version 1
```

Vérifier : `kubectl exec -n garage garage-0 -- /garage status` liste le nœud
**avec un rôle** (plus de « NO ROLE ASSIGNED »).

## 2. Créer le bucket et la clé

```bash
kubectl exec -n garage garage-0 -- /garage bucket create db-backups

# Affiche "Key ID" et "Secret key" : les noter, le secret n'est plus affiché ensuite
kubectl exec -n garage garage-0 -- /garage key create backups-key

kubectl exec -n garage garage-0 -- /garage bucket allow \
  --read --write db-backups --key backups-key
```

Vérifier : `kubectl exec -n garage garage-0 -- /garage bucket info db-backups`
montre `backups-key` autorisée en lecture/écriture.

## 3. Sceller la clé pour les consommateurs

Le futur `Cluster` CloudNativePG lira la clé via un secret exposant
`ACCESS_KEY_ID` / `ACCESS_SECRET_KEY` (contrat décrit dans
`migration-lxc-kubenetes.md` §8.4). On crée ce secret **dans le namespace de
l'app qui sauvegarde** (créé quand CNPG arrivera), pas dans `kubernetes/garage/`.

```bash
kubectl create secret generic garage-app-creds \
  --namespace <ns-de-l-app> \
  --from-literal=ACCESS_KEY_ID=<keyID> \
  --from-literal=ACCESS_SECRET_KEY=<secret> \
  --dry-run=client -o yaml \
  | kubeseal --format yaml \
  > kubernetes/apps/<app>/garage-app-creds-sealed.yaml
```

Côté `Cluster` CNPG, pointer les backups sur Garage :

```yaml
backup:
  barmanObjectStore:
    destinationPath: s3://db-backups/<app>-db
    endpointURL: http://garage.garage.svc:3900   # path-style S3 garanti par l'endpoint explicite
    s3Credentials:
      accessKeyId:
        name: garage-app-creds
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: garage-app-creds
        key: ACCESS_SECRET_KEY
```

## Régénérer le secret racine (rpc/admin)

`kubernetes/garage/garage-secrets-sealed.yaml` contient `GARAGE_RPC_SECRET` et
`GARAGE_ADMIN_TOKEN`. Pour le régénérer :

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
