#!/bin/bash 
# dry_run=true
VERSION='1.0'

help(){
    echo "nasSync - Keep the zfs storage pool syncronized with the NAS"
    echo " Version $VERSION"
    echo "-----------------------------------------------"
    echo "Usage: $(basename "$0") [option]"
    echo ""
    echo "[option]"
    echo "        sync          Syncs the ZFS dataset with the NAS"
    echo "        help          Displays this help message"
}

run_cmd() {
    # Use this only for commanda that change the system. Running multiline commands will fail.
    if [ -v dry_run ]; then
        echo "[DRY RUN] $*"
    else
        "$@"
    fi
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This script must be run as root."
        exit 1
    fi
}


DATECMD=date
readonly timestamp_format="%Y.%m.%d %H:%M:%S"
readonly timestamp
log_file="$HOME/$(basename "$0").log"
export TOP_PID=$$

TEMPSNAPNAME="nasSyncSnapshot"
DATASET="silo/storage"

msg() { echo "[$EPOCHSECONDS] $*" | tee -a $log_file; } 
die() { echo "[$EPOCHSECONDS] [FATAL] $*" | tee -a $log_file; kill -s TERM $TOP_PID; } 

sync_nas(){
    msg "sync started: $($DATECMD "+$timestamp_format")"

    run_cmd zfs snapshot "$DATASET@$TEMPSNAPNAME"
    if [ $? -ne 0 ]; then
        die "Failed to create snapshot for $dataset"
    else
        msg "Created snapshopt $DATASET@$TEMPSNAPNAME"
    fi

    #todo mount
    msg "mounting NAS using NFS"
    sudo mount -t nfs nas.internal:/volume1/srv1-backup /media/srv1/nas
    if [ $? -ne 0 ]; then   
        die " Could not mount remote"
    fi

    msg "Starting rsync"
    rsync -aPvH --omit-dir-times --delete --exclude-from=/etc/nasExclude /silo/storage/.zfs/snapshot/$TEMPSNAPNAME/ /media/srv1/nas/silo/storage/
    if [ $? -ne 0 ]; then   
        msg " [WARN] rsync returned an error!"
    else
        msg "rsync finished"
    fi

    msg "umounting NFS"
    sudo umount /media/srv1/nas 

    msg "deleting snapshot $DATASET@$TEMPSNAPNAME"
    zfs destroy "$DATASET@$TEMPSNAPNAME"

    msg "sync end: $($DATECMD "+$timestamp_format")"
        if [ $? -ne 0 ]; then   
        msg " [WARN] Could not destroy $DATASET@$TEMPSNAPNAME"
    fi

}

who(){
    echo "V3JpdHRlbiBieSBMdWFuIENhcmRvc28gZG9zIFNhbnRvcyBhdCBFZGdlIEFlcm9zcGFjZQo=" | base64 -d
}
#--------------------------

for arg in "$@"; do
    case $arg in
        sync)
            check_root
            sync_nas
            ;;
        who)
            who
            ;;
        *)
            help
            ;;
    esac
done

