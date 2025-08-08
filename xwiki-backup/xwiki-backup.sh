#!/bin/bash 
# small script to backup xwiki data. The script is still wrting in the same disks, so it shouldn't be called
# a proper backup, but itt will keep some history of the xwiki data, that we can use in case of failure.

# In the future, these tarballs should be moved to a different disk, so we can have a proper backup (probably to Edge NAS)
XWIKI_LOCATION=/silo/storage/xwiki
XWIKI_BACKUP_LOCATION=/silo/storage/xwiki-backup
XWIKI_BACKUP_FILE=xwiki-backup-$(date +%Y-%m-%d).tar.gz
ADM_EMAIL="luan.cardoso@edge-aerospace.com"

XWIKI_BACKUP_FILE_PATH=$XWIKI_BACKUP_LOCATION/$XWIKI_BACKUP_FILE

backup() {
    mkdir -p "$XWIKI_BACKUP_LOCATION"
    tar -czf "$XWIKI_BACKUP_FILE_PATH" -C "$XWIKI_LOCATION" .
    #check if the backup was created successfully
    if [ $? -ne 0 ]; then
        echo "Error: Backup failed. Email sent to $ADM_EMAIL"

        sendmail $ADM_EMAIL<<EOF
Subject: XWiki Backup Failed at $XWIKI_BACKUP_FILE_PATH

The backup of XWiki failed. Please check the logs for more details.

sent automatically with sendmail by $0.
EOF
        
        exit 1
    fi  
    backup_info="
Backup created at $XWIKI_BACKUP_FILE_PATH
Backup size: $(du -sh "$XWIKI_BACKUP_FILE_PATH" | cut -f1)
Backup folder size: $(du -sh "$XWIKI_BACKUP_LOCATION" | cut -f1)
SHA1 hash of tarball: $(tar -xOzf "$XWIKI_BACKUP_FILE_PATH" | sha1sum | awk '{print $1}')"

    echo $backup_info

    sendmail $ADM_EMAIL<<EOF
Subject: XWiki Backup $XWIKI_BACKUP_FILE_PATH

The backup of XWiki was created successfully.

$backup_info

sent automatically with sendmail by $0.
EOF


echo "$(date +%Y-%m-%d\ %H:%M:%S) - Backup created: $XWIKI_BACKUP_FILE_PATH size: $(du -b $XWIKI_BACKUP_FILE_PATH | cut -f1) B" >> $XWIKI_BACKUP_LOCATION/backup.log
}

clean() {
    files_to_delete=$(find "$XWIKI_BACKUP_LOCATION" -type f -name 'xwiki-backup-*.tar.gz' -mtime +30)
    if [ -z "$files_to_delete" ]; then
        echo "No backups older than 30 days found in $XWIKI_BACKUP_LOCATION."
        return
    fi

    echo "The following files will be deleted:"
    echo "$files_to_delete"
    read -p "Are you sure you want to delete these files? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "$files_to_delete" | xargs rm
        echo "Backups older than 30 days have been removed from $XWIKI_BACKUP_LOCATION"
    else
        echo "No files were deleted."
    fi
}

analysis() {
    #check if gnuplot is installed
    if ! command -v gnuplot &> /dev/null; then
        echo "gnuplot is not installed. Please install it to use the analysis feature."
        exit 1
    fi

    echo "Analysis of the backup folder:"
    echo "Total size of backup folder: $(du -BM "$XWIKI_BACKUP_LOCATION" | cut -f1)MB"
    echo "Number of backups: $(find "$XWIKI_BACKUP_LOCATION" -type f -name 'xwiki-backup-*.tar.gz' | wc -l)"
    echo "Last backup file: $(ls -lt "$XWIKI_BACKUP_LOCATION" | grep 'xwiki-backup-' | head -n 1 | awk '{print $9}')"
    echo ""
    #get current terminal dimensions
    terminal_width=$(tput cols)
    terminal_height=$(( $(tput lines) - 10 ))
    du -BK "$XWIKI_BACKUP_LOCATION"/*.gz | cut -f1 | tail -n20 | gnuplot -e "set terminal dumb size $terminal_width,$terminal_height; plot '-' with lines"
}


#check if the script is run as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This script must be run as root. Please use sudo."
        exit 1
    fi
}

#read from command line arguments
if [ "$1" == "backup" ]; then
    check_root
    backup
elif [ "$1" == "clean" ]; then
    check_root
    clean
elif [ "$1" == "analysis" ]; then
    analysis
else
    echo "Usage: $0 {backup|clean|analysis}"

    echo "backup: Create a backup of the XWiki data"
    echo "clean: Remove backups older than 30 days"
    echo "analysis: Analyze the backup folder and display statistics and a graph of the backup size over time (gnuplot required)"
    exit 1
fi  

