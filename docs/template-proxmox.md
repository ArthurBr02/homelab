# Créer un template Ubuntu Cloud-Init dans Proxmox

Cette procédure crée un template Ubuntu 24.04 Cloud-Init avec l'agent QEMU, prêt à être cloné.

## 1. Télécharger l'image Ubuntu

Dans l'interface Proxmox :

1. Ouvrir `local`.
2. Sélectionner **ISO Images**.
3. Cliquer sur **Download from URL**.
4. Coller l'URL suivante :

   ```text
   https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
   ```

5. Cliquer sur **Query URL**, puis sur **Download**.

## 2. Créer la VM

Cliquer sur **Create VM**, puis utiliser les paramètres suivants :

| Paramètre | Valeur |
| --- | --- |
| ID | `9000` |
| Nom | `ubuntu-2404-cloudinit` |
| CPU | 2 cœurs |
| RAM | 2 048 Mo |

Configurer ensuite les différents onglets :

- **OS** : cocher **Do not use any media**.
- **System** :
  - cocher **Qemu Agent** ;
  - sélectionner **VirtIO SCSI single** comme contrôleur SCSI.
- **Disks** : supprimer le disque proposé avec le bouton en forme de corbeille.

Cliquer sur **Finish**.

## 3. Installer l'agent QEMU et importer le disque

Ouvrir un shell sur l'hôte Proxmox, puis exécuter :

```bash
apt install -y libguestfs-tools
virt-customize \
  -a /media/storage/template/iso/noble-server-cloudimg-amd64.img \
  --install qemu-guest-agent
qm set 9000 \
  --scsi0 media-storage:0,import-from=/media/storage/template/iso/noble-server-cloudimg-amd64.img
```

Vérifier que le disque système est bien attaché :

```bash
qm config 9000
```

La sortie doit contenir une ligne `scsi0:`. Si cette ligne est absente, ne pas poursuivre la création du template.

## 4. Ajouter le disque Cloud-Init

Dans l'interface Proxmox :

1. Ouvrir la VM `9000`.
2. Aller dans **Hardware**.
3. Cliquer sur **Add**, puis sur **CloudInit Drive**.
4. Sélectionner le stockage `media-storage`.

## 5. Configurer la console série

> Cette étape est obligatoire pour éviter un écran noir au démarrage.

Dans l'onglet **Hardware** de la VM `9000` :

1. Cliquer sur **Add**, puis sur **Serial Port**.
2. Sélectionner le port numéro `0`.
3. Double-cliquer sur **Display**.
4. Choisir **Serial terminal 0**.

## 6. Configurer l'ordre de démarrage

Supprimer le lecteur CD vide créé avec la VM, puis définir `scsi0` comme seul disque de démarrage :

```bash
qm set 9000 --delete ide2
qm set 9000 --boot order=scsi0
```

Vérifier la configuration :

```bash
qm config 9000
```

La sortie doit notamment contenir :

```text
boot: order=scsi0
scsi0: media-storage:9000/...
```

Il est aussi possible de vérifier ce réglage dans **Options → Boot Order**. Le périphérique `scsi0` doit être activé et placé en première position.

## 7. Agrandir le disque système

L'image Ubuntu crée initialement un disque d'environ 3,5 Go. L'agrandir à 20 Go avant de convertir la VM en template :

```bash
qm resize 9000 scsi0 20G
```

Vérifier la nouvelle taille :

```bash
qm config 9000
```

La ligne `scsi0` doit maintenant contenir `size=20G`.

## 8. Convertir la VM en template

Faire un clic droit sur la VM `9000`, puis sélectionner **Convert to template**.
