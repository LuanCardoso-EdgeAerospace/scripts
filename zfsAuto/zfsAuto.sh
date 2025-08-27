#!/bin/bash 
dry_run=true
SCRIPT_TAG="zfsAuto"

# Init variables
DATECMD=date
readonly timestamp_format="%Y%m%d%H%M%S"
timestamp=$($DATECMD "+$timestamp_format")
readonly timestamp
log_file="$HOME/$(basename "$0").log"

trap "exit 1" TERM
export TOP_PID=$$

msg() { echo "$*" 1>&2; } #message to stderr
warn() { msg "WARNING: $*"; }
die() { msg "ERROR: $*"; kill -s TERM $TOP_PID; }

config_read_file() {
  (grep -E "^${2}=" -m 1 "${1}" 2>/dev/null || echo "VAR=__UNDEFINED__") | head -n 1 | cut -d '=' -f 2-;
}

config_get() {
  working_dir="$(dirname "$(readlink -f "$0")")"
  val="$(config_read_file $working_dir/zfsAuto.conf "${1}")";
  if [ "${val}" = "__UNDEFINED__" ]; then
    val="$(config_read_file $working_dir/default.zfsAuto.conf "${1}")";
    if [ "${val}" = "__UNDEFINED__" ]; then
      die "Default configuration file 'default.zfsAuto.conf' is missing or corrupt."
    fi
  fi
  printf -- "%s" "${val}";
}

help(){
    echo "zfsAuto - Automated ZFS Snapshot and Backup Management"
    echo " Version 1.0"
    echo "-----------------------------------------------"
    echo "Usage: $(basename "$0") [option]"
    echo ""
    echo "[option]"
    echo "        snapshot      Creates a snapshot of the zfs filesystem hosting SOURCE_DIR"
    echo "                      and creates a backup tarball if needed"
    echo "        rotate        Removes old snapshots following the retention policy"
    echo "        backup        Creates a backup of SOURCE_DIR to BACKUP_DIR"
    echo "        clean         Cleans up old backups in BACKUP_DIR"
    echo "        report        Reports disk usage of BACKUP_DIR and ZFS snapshots"
    echo "        help          Displays this help message"
}


#check if the script is run as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This script must be run as root."
        exit 1
    fi
}

run_cmd() {
    # Use this only for commanda that change the system. Running multiline commands will fail.
    if [ -v dry_run ]; then
        echo "[DRY RUN] $*"
    else
        "$@"
    fi
}
    

createSnapshot() {
    # Load configuration
    dataset=$(config_get SOURCE_ZFS_DATASET)
    msg "Creating snapshot for $dataset"
    # Create zfs snapshot
    run_cmd zfs snapshot "$dataset@$timestamp-$SCRIPT_TAG"
    # check if the snapshot was created successfully
    if [ $? -ne 0 ]; then
        die "Failed to create snapshot for $dataset"
    fi

    # After creating a snapshot, we check if we need to create a backup tarball
    # based on the TARBALL_FREQUENCY setting.
    # If the frequency is daily, we create a tarball every day.
    # If it's weekly, we create a tarball only on Sundays.
    # If it's monthly, we create a tarball only on the first Sunday of the month.
    # If it's yearly, we create a tarball only on the first Sunday of the year.
    # We assume that the script is run daily via cron.
    tarball_frequency=$(config_get TARBALL_FREQUENCY)
    if [ "$tarball_frequency" == "daily" ]; then
        createBackup
    fi
    if [ "$tarball_frequency" == "weekly" ] && [ "$(date +%u)" -eq 7 ]; then
        createBackup
    fi
    if [ "$tarball_frequency" == "monthly" ] && [ "$(date +%u)" -eq 7 ] && [ "$(date +%d)" -le 7 ]; then
        createBackup
    fi
    if [ "$tarball_frequency" == "yearly" ] && [ "$(date +%u)" -eq 7 ] && [ "$(date +%m)" -eq 1 ] && [ "$(date +%d)" -le 7 ]; then
        createBackup
    fi
}

createBackup() {
    SOURCE_DIR=$(config_get SOURCE_DIR)
    BACKUP_DIR=$(config_get BACKUP_DIR)
    SOURCE_ZFS_DATASET=$(config_get SOURCE_ZFS_DATASET)
    msg "Creating backup for $SOURCE_DIR"
    # Find the latest snapshot
    SNAPSHOT=$(zfs list -t snapshot -o name -s creation | grep "$SCRIPT_TAG" | tail -n 1)
    if [ -z $SNAPSHOT ]; then
        die "No snapshot found for $SOURCE_DIR. Please create a snapshot first."
    fi

    # create a tarball of the snapshot
    BACKUP_FILE="${BACKUP_DIR}backup-$timestamp-$SCRIPT_TAG.tar.gz"
    SOURCE_SNAPSHOT_DIR=/$SOURCE_ZFS_DATASET/.zfs/snapshot/$(echo $SNAPSHOT | cut -d'@' -f2)/${SOURCE_DIR#*$SOURCE_ZFS_DATASET/}
    msg "The snapshotdirectory is $SOURCE_SNAPSHOT_DIR"
    msg "Creating tarball $BACKUP_FILE from $SOURCE_SNAPSHOT_DIR"
    run_cmd tar -czf "$BACKUP_FILE" -C "$SOURCE_SNAPSHOT_DIR" .
    if [ $? -ne 0 ]; then
        die "Failed to create backup tarball $BACKUP_FILE"
    fi
}


# We should only operate on snapshots created by this script
# the name will always end with $SCRIPT_TAG.
rotateSnapshots() {
    SOURCE_ZFS_DATASET=$(config_get SOURCE_ZFS_DATASET)
    msg "removing old backups for $SOURCE_ZFS_DATASET"
    #read retention policy from config
    BACKUP_DIR=$(config_get BACKUP_DIR)
    DAILY_BACKUPS=$(config_get DAILY_BACKUPS)
    WEEKLY_BACKUPS=$(config_get WEEKLY_BACKUPS)
    MONTHLY_BACKUPS=$(config_get MONTHLY_BACKUPS)
    YEARLY_BACKUPS=$(config_get YEARLY_BACKUPS)

    # list all the snapshots
    snapshots=$(zfs list -t snapshot -o name -s creation | grep "$SCRIPT_TAG")
    # snapshots=$(./tmpTestData.sh)tmpTestData
   
    # generate the list of snapshots to keep
    keep_list=()
    # we use the timestamps in the snapshot names to determine which snapshots to keep.
    for snapshot in $snapshots; do
        # Extract the full timestamp: YYYYMMDDHHMMSS
        snap_ts=$(echo "$snapshot" | cut -d@ -f2 | cut -d- -f1)

        # Convert to a proper date format YYYY-MM-DD for date calculations
        snap_date="${snap_ts:0:4}-${snap_ts:4:2}-${snap_ts:6:2}"

        snap_year=$(date -d "$snap_date" +%Y)
        snap_month=$(date -d "$snap_date" +%m)
        snap_day=$(date -d "$snap_date" +%d)
        snap_weekday=$(date -d "$snap_date" +%u) # 1 (Monday) to 7 (Sunday)

        # === Daily backups ===
        if [ "$(date -d "$snap_date" +%s)" -ge "$(date -d "-$DAILY_BACKUPS days" +%s)" ]; then
            keep_list+=("$snapshot")
            continue
        fi

        # === Weekly backups (keep if it's Sunday) ===
        if [ "$snap_weekday" -eq 7 ] && \
        [ "$(date -d "$snap_date" +%s)" -ge "$(date -d "-$WEEKLY_BACKUPS weeks" +%s)" ]; then
            keep_list+=("$snapshot")
            continue
        fi

        # === Monthly backups (keep if it's the first Sunday of the month) ===
        if [ "$snap_weekday" -eq 7 ] && [ "$snap_day" -le 7 ] && \
        [ "$(date -d "$snap_date" +%s)" -ge "$(date -d "-$MONTHLY_BACKUPS months" +%s)" ]; then
            keep_list+=("$snapshot")
            continue
        fi

        # === Yearly backups (keep if it's the first Sunday of the year) ===
        if [ "$snap_weekday" -eq 7 ] && [ "$snap_month" -eq 1 ] && [ "$snap_day" -le 7 ] && \
        [ "$(date -d "$snap_date" +%s)" -ge "$(date -d "-$YEARLY_BACKUPS years" +%s)" ]; then
            keep_list+=("$snapshot")
            continue
        fi
    done

    # remove duplicates from keep_list
    keep_list=($(echo "${keep_list[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

    # filter out the snapshots to keep from the full list
    remove_list=()
    for snapshot in $snapshots; do
        if [[ ! " ${keep_list[*]} " =~ " ${snapshot} " ]]; then
            remove_list+=("$snapshot")
        fi
    done    

    if [ ${#remove_list[@]} -eq 0 ]; then
        msg "No snapshots to remove."
        return
    fi
    msg "The following snapshots will be removed:"
    for snapshot in "${remove_list[@]}"; do
        msg " - $snapshot"
    done

    read -p "Are you sure you want to delete these snapshots? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        for snapshot in "${remove_list[@]}"; do
            msg "Removing snapshot $snapshot"
            run_cmd zfs destroy "$snapshot"
            if [ $? -ne 0 ]; then
                warn "Failed to remove snapshot $snapshot"
            fi
        done
        msg "Old snapshots have been removed."
    else
        msg "No snapshots were deleted."
    fi
}

cleanBackup() {
    BACKUP_DIR=$(config_get BACKUP_DIR)
    TARBALL_RETENTION=$(config_get TARBALL_RETENTION)
    #list all tarballs in the backup directory, sorted by creation date, without the most recent ones
    files=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "backup-*-$SCRIPT_TAG.tar.gz" \
        -printf "%T@ %p\n" | sort -nr | cut -d' ' -f2- | tail -n +$TARBALL_RETENTION)

    if [ -z "$files" ]; then
        msg "No old backup tarballs to remove."
        return
    fi  

    msg "The following backup tarballs will be removed:"
    echo "$files"
    read -p "Are you sure you want to delete these files? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if [ -v dry_run ]; then
            echo "[DRY RUN] rm $files"
        else
            echo "$files" | xargs -d '\n' rm
        fi
        msg "Old backup tarballs have been removed from $BACKUP_DIR"
    else
        msg "No files were deleted."
    fi

}


reportDiskUsage(){
    # Report the disk usage of the backup directory
    # and the used space by the zfs snapshots.

    msg "Disk usage report for $BACKUP_DIR and ZFS snapshots of $SOURCE_DIR" 
    BACKUP_DIR=$(config_get BACKUP_DIR)
    SOURCE_DIR=$(config_get SOURCE_DIR)
    SOURCE_ZFS_DATASET=$(config_get SOURCE_ZFS_DATASET)

    echo "Total size of backup directory $BACKUP_DIR: $(du -sh "$BACKUP_DIR" | cut -f1)"
    echo "Total size of ZFS dataset $SOURCE_ZFS_DATASET: $(zfs list -H -o used "$SOURCE_ZFS_DATASET")"
}

#--------------------------------------------------------------------------------------------#



# check if another instance of this script is running
if pidof -o %PPID -x "$(basename "$0")"; then
    die "Another instance of $(basename "$0") is already running."
fi

for arg in "$@"; do
    case $arg in
        snapshot)
            check_root
            createSnapshot
            ;;
        rotate)
            check_root
            rotateSnapshots
            ;;
        backup)
            check_root
            createBackup
            ;;
        clean)
            cleanBackup
            ;;
        report)
            reportDiskUsage
            ;;
        help|--help|-h)
            help
            exit 0
            ;;
        who)
            echo "Written by Luan Cardoso dos Santos at Edge Aerospace"
            ;;
        *)
            die "Unknown argument: $arg. Use 'help' to see available options."
            ;;
    esac
done

