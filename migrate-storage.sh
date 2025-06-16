#!/bin/bash

###############################################
## Proxmox Cluster Storage Migrator v1.5.7.8 ##
###############################################

### Inspired and directed by SkrIN, written by ChatGPT, GNU GPLv3
### Always run with --dry-run for the first time!!!
### If you are interested in rename function of this script,
### check the main function in the end of this file.
### Renaming is optimized for NFS mounts only!!!

SRC_STORAGE="storage-1"
DST_STORAGE="storage-2"
RENAMED_STORAGE="storage-1-renamed"
STORAGE_CFG="/etc/pve/storage.cfg"
STATE_FILE="migrate-storage.map"
MIGRATED_DST="migrated-to-dst.list"
MIGRATED_BACK="migrated-back.list"
LOG_FILE="migrate-storage.log"
LOCKFILE="/var/lock/migrate-storage.lock"
MOUNT_BASE="/mnt/pve"
DRY_RUN=0

COL_INFO="\033[1;34m"
COL_WARN="\033[1;33m"
COL_ERROR="\033[1;31m"
COL_SUCCESS="\033[1;32m"
COL_RESET="\033[0m"

exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "Script is already running, exiting."
  exit 1
fi

log() {
  TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
  LEVEL=$1
  MESSAGE=$2
  case "$LEVEL" in
    INFO) COLOR=$COL_INFO ;;
    WARN) COLOR=$COL_WARN ;;
    ERROR) COLOR=$COL_ERROR ;;
    SUCCESS) COLOR=$COL_SUCCESS ;;
    *) COLOR=$COL_RESET ;;
  esac
  echo -e "${TIMESTAMP} [${LEVEL}] ${COLOR}${MESSAGE}${COL_RESET}"
  echo "${TIMESTAMP} [${LEVEL}] ${MESSAGE}" >> "$LOG_FILE"
}

safe_run() {
  CMD="$1"
  log "COMMAND" "$CMD"
  if [ $DRY_RUN -eq 1 ]; then
    echo "[DRY-RUN] Skipping execution"
    return 0
  fi
  if ! eval "$CMD"; then
    log "ERROR" "Command failed, continuing."
    return 1
  fi
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--dry-run) DRY_RUN=1; shift ;;
    *) log "WARN" "Unknown parameter: $1"; shift ;;
  esac
done

if [ $DRY_RUN -eq 1 ]; then log "WARN" "!!! DRY-RUN MODE ENABLED !!!"; fi

##########################################
# CLUSTER VALIDATION
##########################################

validate_storage() {
  local STORAGE_NAME=$1
  if ! grep -q ": $STORAGE_NAME$" "$STORAGE_CFG"; then
    log "ERROR" "Storage $STORAGE_NAME not found in $STORAGE_CFG"
    exit 1
  else
    log "INFO" "Storage $STORAGE_NAME exists"
  fi
}

log "INFO" "Validating cluster..."
validate_storage "$SRC_STORAGE"
validate_storage "$DST_STORAGE"
NODES=$(ls /etc/pve/nodes)
for NODE in $NODES; do
  ssh -o BatchMode=yes -o ConnectTimeout=5 root@$NODE "hostname" >/dev/null 2>&1 || { log "ERROR" "SSH not available on $NODE"; exit 1; }
  log "INFO" "SSH OK: $NODE"
done
log "SUCCESS" "Cluster validation successful."

##########################################
# GENERATE MIGRATION PLAN
##########################################

generate_state_file() {
  log "INFO" "Generating migration plan to $STATE_FILE"
  TMPFILE=$(mktemp)
  echo -e "node\tvmid\ttype\tdevice\tvolume" > "$TMPFILE"

  for NODE in $NODES; do
    for CONF in /etc/pve/nodes/$NODE/qemu-server/*.conf; do
      [ -e "$CONF" ] || continue
      VMID=$(basename "$CONF" .conf)
      TYPE="qemu"
      grep -E "^(ide|sata|scsi|virtio|efidisk|tpmstate)[0-9]+:" "$CONF" | while read -r LINE; do
        DEVICE=$(echo "$LINE" | cut -d':' -f1)
        REST=$(echo "$LINE" | cut -d':' -f2- | xargs)
        STORAGE=$(echo "$REST" | cut -d':' -f1)
        REMAINDER=$(echo "$REST" | cut -d':' -f2-)
        VOLUME=$(echo "$REMAINDER" | cut -d',' -f1)
        if [[ "$STORAGE" == "$SRC_STORAGE" ]]; then
          echo -e "${NODE}\t${VMID}\t${TYPE}\t${DEVICE}\t${STORAGE}:${VOLUME}" >> "$TMPFILE"
        fi
      done
    done

    for CONF in /etc/pve/nodes/$NODE/lxc/*.conf; do
      [ -e "$CONF" ] || continue
      VMID=$(basename "$CONF" .conf)
      TYPE="lxc"
      grep -E "^(rootfs|mp[0-9]+):" "$CONF" | while read -r LINE; do
        DEVICE=$(echo "$LINE" | cut -d':' -f1)
        REST=$(echo "$LINE" | cut -d':' -f2- | xargs)
        STORAGE=$(echo "$REST" | cut -d':' -f1)
        REMAINDER=$(echo "$REST" | cut -d':' -f2-)
        VOLUME=$(echo "$REMAINDER" | cut -d',' -f1)
        if [[ "$STORAGE" == "$SRC_STORAGE" ]]; then
          echo -e "${NODE}\t${VMID}\t${TYPE}\t${DEVICE}\t${STORAGE}:${VOLUME}" >> "$TMPFILE"
        fi
      done
    done
  done

  mv "$TMPFILE" "$STATE_FILE"
  log "SUCCESS" "Migration plan generated."
}

if [ ! -f "$STATE_FILE" ]; then
  generate_state_file
fi

##########################################
# CHECK FREE SPACE
##########################################

log "INFO" "Checking capacity via pvesm status"
SRC_USED=$(pvesm status | awk -v S="$SRC_STORAGE" '$1==S {print $5}')
DST_AVAIL=$(pvesm status | awk -v D="$DST_STORAGE" '$1==D {print $6}')
log "INFO" "Source storage uses $SRC_USED B"
log "INFO" "Destination storage has $DST_AVAIL B available"
if [ "$DST_AVAIL" -lt "$SRC_USED" ]; then
  log "ERROR" "Not enough free space on destination storage!"
  exit 1
fi
log "SUCCESS" "Enough space on destination storage."

touch "$MIGRATED_DST" "$MIGRATED_BACK"

##########################################
# MIGRATION TO DESTINATION STORAGE
##########################################

migrate_to_dst() {
  log "INFO" "Moving disks to $DST_STORAGE"
  mapfile -t LINES < <(tail -n +2 "$STATE_FILE")
  for LINE in "${LINES[@]}"; do
    IFS=$'\t' read -r NODE VMID TYPE DEVICE VOLUME <<< "$LINE"
    KEY="${NODE}_${VMID}_${DEVICE}"
    grep -q "$KEY" "$MIGRATED_DST" && continue

    log "INFO" "Moving $TYPE / $VMID / $DEVICE to $DST_STORAGE"
    if [ "$TYPE" == "qemu" ]; then
      if safe_run "ssh root@$NODE \"qm disk move $VMID $DEVICE $DST_STORAGE --delete 1\""; then
        echo "$KEY" >> "$MIGRATED_DST"
      fi
    else
      safe_run "ssh root@$NODE \"pct shutdown $VMID --force-stop 1\""
      if safe_run "ssh root@$NODE \"pct move-volume $VMID $DEVICE $DST_STORAGE --delete 1\""; then
        echo "$KEY" >> "$MIGRATED_DST"
      fi
      safe_run "ssh root@$NODE \"pct start $VMID\""
    fi
  done
  log "SUCCESS" "Migration to $DST_STORAGE completed."
}

##########################################
# CHECK IF SOURCE STORAGE IS EMPTY
##########################################

check_empty() {
  log "INFO" "Checking if $SRC_STORAGE is empty"

  if [ $DRY_RUN -eq 1 ]; then
    log "WARN" "DRY-RUN: Skipping check if storage is empty."
    return 0
  fi

  STILL_USED=0
  for NODE in $NODES; do
    for CONF in /etc/pve/nodes/$NODE/qemu-server/*.conf /etc/pve/nodes/$NODE/lxc/*.conf; do
      [ -e "$CONF" ] || continue
      if grep -q "$SRC_STORAGE:" "$CONF"; then
        log "ERROR" "Still used in: $CONF"
        STILL_USED=$((STILL_USED+1))
      fi
    done
  done

  if [ "$STILL_USED" -ne 0 ]; then
    log "ERROR" "Storage still contains $STILL_USED items — migration cannot proceed."
    exit 1
  fi

  log "SUCCESS" "Storage $SRC_STORAGE is empty."
}

##########################################
# RENAME STORAGE v1.5.7.8
##########################################

rename_storage() {
  log "INFO" "Disabling storage $SRC_STORAGE in cluster"
  safe_run "pvesm set $SRC_STORAGE --disable 1"

  log "INFO" "Unmounting storage $SRC_STORAGE on all nodes"
  for NODE in $NODES; do
    safe_run "ssh root@$NODE \"umount $MOUNT_BASE/$SRC_STORAGE || true\""
  done

  log "INFO" "Backing up $STORAGE_CFG -> ${STORAGE_CFG}.bak.$(date +%Y%m%d%H%M%S)"
  safe_run "cp \"$STORAGE_CFG\" \"${STORAGE_CFG}.bak.$(date +%Y%m%d%H%M%S)\""

  log "INFO" "Renaming storage name in $STORAGE_CFG"
  safe_run "sed -i \"s/^nfs: $SRC_STORAGE\$/nfs: $RENAMED_STORAGE/\" \"$STORAGE_CFG\""

  log "INFO" "Renaming path in $STORAGE_CFG"
  safe_run "sed -i \"s|path /mnt/pve/$SRC_STORAGE|path /mnt/pve/$RENAMED_STORAGE|\" \"$STORAGE_CFG\""

  log "INFO" "Enabling storage $RENAMED_STORAGE in cluster"
  safe_run "pvesm set $RENAMED_STORAGE --disable 0"

  log "INFO" "Validating if storage $RENAMED_STORAGE now exists"
  if [ $DRY_RUN -eq 1 ]; then
    log "WARN" "DRY-RUN: Skipping validation of $RENAMED_STORAGE existence"
  else
    if grep -q ": $RENAMED_STORAGE\$" "$STORAGE_CFG"; then
      log "SUCCESS" "Storage $RENAMED_STORAGE found in configuration."
    else
      log "ERROR" "Storage $RENAMED_STORAGE not found in $STORAGE_CFG! Rename failed."
      exit 1
    fi
  fi

  log "SUCCESS" "Storage $SRC_STORAGE successfully renamed to $RENAMED_STORAGE and ready."
}

##########################################
# MIGRATION BACK
##########################################

migrate_back() {
  log "INFO" "Moving back to $RENAMED_STORAGE"
  mapfile -t LINES < <(tail -n +2 "$STATE_FILE")
  for LINE in "${LINES[@]}"; do
    IFS=$'\t' read -r NODE VMID TYPE DEVICE VOLUME <<< "$LINE"
    KEY="${NODE}_${VMID}_${DEVICE}"
    grep -q "$KEY" "$MIGRATED_BACK" && continue

    log "INFO" "Moving back $TYPE / $VMID / $DEVICE to $RENAMED_STORAGE"
    if [ "$TYPE" == "qemu" ]; then
      if safe_run "ssh root@$NODE \"qm disk move $VMID $DEVICE $RENAMED_STORAGE --delete 1\""; then
        echo "$KEY" >> "$MIGRATED_BACK"
      fi
    else
      safe_run "ssh root@$NODE \"pct shutdown $VMID --force-stop 1\""
      if safe_run "ssh root@$NODE \"pct move-volume $VMID $DEVICE $RENAMED_STORAGE --delete 1\""; then
        echo "$KEY" >> "$MIGRATED_BACK"
      fi
      safe_run "ssh root@$NODE \"pct start $VMID\""
    fi
  done
  log "SUCCESS" "Move back completed."
}

##########################################
# MAIN WORKFLOW
##########################################

main() {
  migrate_to_dst
  check_empty
  ### Uncomment rename_storage below if you want to also rename storage ###
  #rename_storage
  ### Uncomment migrate_back below if you want to also move disks back ###
  #migrate_back
  log "SUCCESS" "✅ MIGRATION FULLY COMPLETED ✅"
}

main
