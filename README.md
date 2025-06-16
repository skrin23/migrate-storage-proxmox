# Proxmox Cluster Storage Migrator

**Version:** v1.5.7.8

---

## 📝 About

A Bash automation script for **safe and repeatable migration of VM and CT disks between NFS storages in a Proxmox cluster**.
Inspired, directed and edited by SkrIN, written by ChatGPT.

- **Run as root:** Run on any node of the cluster
- **Cluster-wide:** Works across all nodes
- **Safe resume:** Interruptible and resumable at any step
- **Dry-run mode:** Test all actions before any change
- **Rename option:** Supports storage rename after migration
- **Full logging:** All actions are logged

---

## 🚀 Usage

### 1️⃣ Configuration

Edit the following variables at the top of the script to match your environment:

```bash
SRC_STORAGE="storage-1"          # Source storage to migrate from
DST_STORAGE="storage-2"          # Target storage for migration
RENAMED_STORAGE="storage-1-renamed"  # New name for source storage after migration (optional)
```

### 2️⃣ First run: Always use DRY-RUN

Before any real migration, simulate all actions and check the migration plan:

./migrate-storage.sh --dry-run

Nothing is changed or moved! Migration plan is generated: **migrate-storage.map**. Check logs for errors/warnings: **migrate-storage.log**

### 3️⃣ Production run

After verifying the DRY-RUN, delete files **migrated-to-dst.list** and **migrated-back.list** and
start the actual migration:

./migrate-storage.sh

### 4️⃣ Customizing the Workflow

By default, only migration to the new storage and "empty source check" are enabled.
To also rename storage and migrate disks back, uncomment these lines in the main() function:

**#rename_storage** and **#migrate_back**

Renaming of the storage only works with NFS mounts!!!

### 5️⃣ Resuming Interrupted Migration

If the script is interrupted, simply run it again — already processed disks are skipped
automatically.

Do not delete the .list or .map files unless you want to start over.

### 📄 Files Created

migrate-storage.map — migration plan (do not delete between runs!)

migrated-to-dst.list — list of disks moved to the new storage

migrated-back.list — list of disks moved back (if using this option)

migrate-storage.log — full action log

### ℹ️ Notes

All actions are logged to both terminal and log file.

Locking: Only one script instance can run at a time (flock is used).

Backup: When renaming, the original storage.cfg is automatically backed up.

Path and storage name are both renamed in the config when using the rename step.

### ⚠️ Safety Tips

Always run a full DRY-RUN first!

Snapshot your Proxmox config (and VM disks if possible) before production migration.

If in doubt, check migrate-storage.log for details about every step.

### ⚙️ Compatibility & Disclaimer

**Tested on Proxmox VE 8.4.1**

**Use as is. Without any warranty or guarantee.**

## Always review and test in your environment before production use.

### 🛡 License
GNU GPL v3 — free to use, share, and improve.
