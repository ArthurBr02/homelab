# Se connecter à une base PostgreSQL du cluster

Guide rapide pour ouvrir une session `psql` sur une base CloudNativePG.

Exemples avec :

- namespace : `mon-app` ;
- cluster PostgreSQL : `mon-app-db` (pod primaire `mon-app-db-1`) ;
- base et utilisateur applicatif : `mon_app`.

Remplacer ces valeurs selon l'application.

## 1. Trouver le pod primaire

CloudNativePG nomme les pods `<cluster>-1`, `<cluster>-2`, etc. Récupérer le
primaire par son label plutôt que par un numéro fixe :

```bash
POD=$(sudo kubectl -n mon-app get pod \
  -l cnpg.io/cluster=mon-app-db,role=primary \
  -o jsonpath='{.items[0].metadata.name}')
echo "$POD"
```

Utiliser `$POD` dans les commandes suivantes, ou le nom en dur (`mon-app-db-1`).

## 2. Session psql depuis le pod (le plus simple)

Dans le pod, l'utilisateur `postgres` est superuser en accès local (trust), donc
pas de mot de passe à fournir :

```bash
sudo kubectl -n mon-app exec -it "$POD" -- psql -U postgres -d mon_app
```

Requête ponctuelle sans session interactive (`-c`) :

```bash
sudo kubectl -n mon-app exec -i "$POD" -- \
  psql -U postgres -d mon_app -c 'SELECT current_database(), current_user;'
```

Lister les tables : ajouter `-c '\dt'`. Décrire une table : `-c '\d nom_table'`.

## 3. Se connecter avec l'utilisateur applicatif

CloudNativePG crée le Secret `<cluster>-app` avec `username`, `password`,
`dbname`, `uri`, etc. Pour se connecter comme l'app (droits restreints à sa base) :

```bash
sudo kubectl -n mon-app exec -i "$POD" -- \
  sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U mon_app -d mon_app -c "\dt"'
```

Consulter les identifiants ponctuellement (éviter de les laisser dans l'historique) :

```bash
sudo kubectl -n mon-app get secret mon-app-db-app \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

## 4. Importer / exécuter un fichier SQL

Pipe le fichier local sur le stdin de `psql` (pas besoin de `sudo kubectl cp`).
`ON_ERROR_STOP=1` interrompt à la première erreur ; encadrer le fichier de
`BEGIN; ... COMMIT;` garantit un rollback complet en cas d'échec :

```bash
sudo kubectl -n mon-app exec -i "$POD" -- \
  psql -U postgres -d mon_app -v ON_ERROR_STOP=1 \
  < chemin/vers/fichier.sql
```

Dump de la base vers un fichier local :

```bash
sudo kubectl -n mon-app exec -i "$POD" -- \
  pg_dump -U postgres -d mon_app > mon_app-dump.sql
```

## 5. Accès depuis la machine locale (port-forward)

Pour brancher un client graphique (DBeaver, TablePlus, DataGrip) ou un `psql`
local, exposer le service `-rw` en local :

```bash
sudo kubectl -n mon-app port-forward svc/mon-app-db-rw 5432:5432
```

Puis, dans un autre terminal, avec les identifiants du Secret `-app` :

```bash
PGPASSWORD='<password>' psql -h 127.0.0.1 -p 5432 -U mon_app -d mon_app
```

Le port-forward reste actif tant que la commande tourne ; `Ctrl+C` pour couper.
Si le port `5432` est déjà pris localement (Postgres local), mapper autrement :
`sudo kubectl port-forward svc/mon-app-db-rw 5433:5432` puis `-p 5433`.

## 6. Erreurs fréquentes

| Symptôme | Cause | Correction |
| --- | --- | --- |
| `psql: could not connect` en local | Pas de port-forward actif | Relancer `sudo kubectl port-forward` dans un terminal dédié |
| `password authentication failed` | Mauvais utilisateur ou mot de passe | Utiliser `postgres` dans le pod, ou relire le Secret `-app` |
| `bind: address already in use` | Port `5432` déjà utilisé en local | Mapper sur un autre port (`5433:5432`) |
| `$POD` vide | Nouveau shell, variable perdue | Relancer la commande de l'étape 1 |
