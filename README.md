# migrate-storage-proxmox
Proxmox Cluster Storage Migrator

Version: v1.5.7.8

About

A Bash-based automation script for safe and repeatable migration of VM and CT disks between NFS storages in a Proxmox cluster.
Cluster-wide: Works across all nodes.
Safe resume: Interruptible, can be re-run at any step.
Dry-run mode: Test all steps before production use.
Rename option: Supports storage rename after migration. Works for NFS mounts only!!!
Full logging: All actions are logged.

Usage

1. Configuration
Edit these variables at the top of the script to match your environment:
SRC_STORAGE="tnas-sitel1-ssd1-1TB"        # Source storage to migrate from
DST_STORAGE="tnas-sitel1-hdd1-2TB"        # Target storage for migration
RENAMED_STORAGE="tnas-sitel1-ssd1-1TB-renamed"  # New name for source storage after migration (optional)

2. First run: Always use DRY-RUN
Before any real migration, check the plan and simulate all actions:
./migrate-storage.sh --dry-run
Nothing is changed or moved!
Migration plan is generated: migrate-storage.map
Check logs for errors/warnings: migrate-storage.log

3. Production run:
After verifying the DRY-RUN:
./migrate-storage.sh

4. Customizing the workflow
By default, only migration to the new storage and empty check is enabled.
To also rename the storage and migrate disks back, uncomment these in the main() function:
#rename_storage
#migrate_back

5. Resuming interrupted migration
If the script is interrupted, just run it again — already processed disks are skipped.
Do not delete the .list or .map files unless you want to start over.

Files created

migrate-storage.map — migration plan (do not delete between runs!)
migrated-to-dst.list — which disks have been moved to the new storage
migrated-back.list — which disks have been moved back (if using this option)
migrate-storage.log — full action log

Notes
All actions are logged to both terminal and log file.
Locking: Only one script instance can run at a time (flock).
Backup: When renaming, the original storage.cfg is backed up automatically.
Storage path and storage name are both renamed in config when using the rename step.

Safety tips
Always run a full DRY-RUN first!
Snapshot your Proxmox config (and VM disks if possible) before real migration.
If in doubt, check migrate-storage.log for details of every step.

License
GNU GPL v3 — free to use, share, improve.
