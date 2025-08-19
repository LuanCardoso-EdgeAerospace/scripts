#!/bin/bash 
# This script is a natural evolution of the xwiki-backup script, designed to handle all the docker containers
# The backup process is based on two main components:
# 1. Full directory copies using rsync, and hardlinks to save space.
# 2. Tarballs for each directory, done less often.

source .env

#check if the script is run as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This script must be run as root. Please use sudo."
        exit 1
    fi
}

# Perform a backup by generating a compressed tarball.
backup_full(){
    BACKUP_FILE="$BACKUP_DIR/tarballs/fb_$(date +%s.%3N).tar.gz" # timestamped filename with milliseconds
    mkdir -p "$BACKUP_DIR/tarballs"
    tar -czf "$BACKUP_FILE" -C "$SOURCE_DIR" .

    if [ $? -ne 0 ]; then
        echo "Error: Full backup failed."
        echo "$(date +%Y-%m-%d\ %H:%M:%S) - Backup failed: $BACKUP_FILE" >> "$BACKUP_DIR/backupTarball.log.err"
        exit 1
    fi

    # write log
    LOG_ENTRY="$(date +%Y-%m-%d\ %H:%M:%S) - Backup created: $BACKUP_FILE size: $(du -b $BACKUP_FILE | cut -f1) B"
    echo "$LOG_ENTRY" | tee -a "$BACKUP_DIR/backupTarball.log"
}

# Executes backup by using rsync to copy the entire directory.
# If a previous backup exists, hardlinks are created to save space; otherwise, the first backup is a full copy.
backup_incremental() {
    THIS_BACKUP_DIR="$BACKUP_DIR/incremental/$(date +%Y%m%d_%H%M%S)"
    LAST_BACKUP_DIR=$(ls -td "$BACKUP_DIR/incremental/"* | tail -n 1)
    mkdir -p "$THIS_BACKUP_DIR"
    # get the last backup directory
    echo "Last backup directory: $LAST_BACKUP_DIR (expected)"
    if [ -z "$LAST_BACKUP_DIR" ]; then
        echo "No previous backup found, performing full backup."
        # just copy the directory
        rsync -a --delete "${SOURCE_DIR}/" "${THIS_BACKUP_DIR}"
    else
        echo "Performing incremental backup based on last backup: $LAST_BACKUP_DIR"
        # use rsync to copy the directory, matching hardlinks against the last backup
        rsync -a --delete --link-dest="$LAST_BACKUP_DIR" "$SOURCE_DIR/" "$THIS_BACKUP_DIR"
    fi
    if [ $? -ne 0 ]; then
        echo "Error: Incremental backup failed."
        echo "$(date +%Y-%m-%d\ %H:%M:%S) - Backup failed: $THIS_BACKUP_DIR" >> "$BACKUP_DIR/backupIncremental.log.err"
        exit 1
    fi
    # write log
    echo "$(date +%Y-%m-%d\ %H:%M:%S) - Backup created: $THIS_BACKUP_DIR size: $(du -bs $THIS_BACKUP_DIR | cut -f1) B" | tee -a "$BACKUP_DIR/backupIncremental.log"
}

analysis_full() {
    #check if gnuplot is installed
    if ! command -v gnuplot &> /dev/null; then
        echo "gnuplot is not installed. Please install it to use the analysis feature."
        exit 1
    fi
    echo "Total size of backup folder: $(du -BM "$BACKUP_DIR/tarballs" | cut -f1)B"
    echo "Number of full backups: $(find "$BACKUP_DIR/tarballs" -type f -name 'fb_*.tar.gz' | wc -l)"
    LAST_BACKUP_FILE=$(ls -lt "$BACKUP_DIR/tarballs" | grep 'fb_' | head -n 1 | awk '{print $9}')
    echo "Last full backup file: $LAST_BACKUP_FILE $(du -h "$BACKUP_DIR/tarballs/$LAST_BACKUP_FILE" | cut -f1)B"
    echo ""
    #get current terminal dimensions
    terminal_width=$(tput cols)
    terminal_height=$(( $(tput lines) - 10 ))
    du -BK "$BACKUP_DIR/tarballs"/*.gz \
    | cut -f1 \
    | tail -n 80 \
    | gnuplot -e "set terminal dumb size $terminal_width,$terminal_height; plot '-' with lines title 'tarballs'"
}

#similar to analysis_full, but report based on the size of each folder in the incremental backup directory
# TODO: Buggy code, not ready for production use.
analysis_incremental() {
    echo "partial analysis of the incremental backup folder has not been tested, so it was disabled. Source \
    is available in the script, with no warranty of any kind."
    # #check if gnuplot is installed
    # if ! command -v gnuplot &> /dev/null; then
    #     echo "gnuplot is not installed. Please install it to use the analysis feature."
    #     exit 1
    # fi
    # echo "Analysis of the incremental backup folder:"
    # echo "Total size of backup folder: $(du -BMs "$BACKUP_DIR/incremental" | cut -f1)MB"
    # echo "Number of incremental backups: $(find "$BACKUP_DIR/incremental" -mindepth 1 -maxdepth 1 -type d | wc -l)"
    # LAST_BACKUP_DIR=$(ls -td "$BACKUP_DIR/incremental/"* | head -n 1)
    # echo "Last incremental backup directory: $LAST_BACKUP_DIR $(du -hs "$LAST_BACKUP_DIR" | cut -f1)"
    # echo ""
    # #get current terminal dimensions
    # terminal_width=$(tput cols)
    # terminal_height=$(( $(tput lines) - 10 ))

    # # Get all unique folder names in SOURCE_DIR
    # FOLDERS=()
    # while IFS= read -r -d '' dir; do
    #     FOLDERS+=("$(basename "$dir")")
    # done < <(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)
        
    # # Get all incremental backup directories sorted by name (date)
    # BACKUP_DIRS=()
    # while IFS= read -r -d '' dir; do
    #     BACKUP_DIRS+=("$dir")
    # done < <(find "$BACKUP_DIR/incremental" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

    # # Prepare data for gnuplot
    # TMPFILE=$(mktemp)
    # # Print header: date folder1 folder2 ...
    # printf "date" > "$TMPFILE"
    # for folder in "${FOLDERS[@]}"; do
    #     printf " %s" "$folder" >> "$TMPFILE"
    # done
    # printf "\n" >> "$TMPFILE"

    # for backup in "${BACKUP_DIRS[@]}"; do
    #     # Extract date from backup folder name
    #     backup_date=$(basename "$backup")
    #     printf "%s" "$backup_date" >> "$TMPFILE"
    #     for folder in "${FOLDERS[@]}"; do
    #         size=$(du -s "$backup/$folder" 2>/dev/null | awk '{print $1}')
    #         printf " %s" "${size:-0}" >> "$TMPFILE"
    #     done
    #     printf "\n" >> "$TMPFILE"
    # done

    # # Generate gnuplot script
    # GNUPLOT_SCRIPT=$(mktemp)
    # {
    #     echo "set terminal dumb size $terminal_width,$terminal_height"
    #     echo "set key autotitle columnhead"
    #     echo "set style data lines"
    #     echo "set title 'Incremental Backup Folder Sizes'"
    #     echo "set xlabel 'Backup Date'"
    #     echo "set ylabel 'Size (KB)'"
    #     echo "plot for [col=2:${#FOLDERS[@]}+1] '$TMPFILE' using 0:col with lines lw 2"
    # } > "$GNUPLOT_SCRIPT"

    # gnuplot "$GNUPLOT_SCRIPT"

    # rm -f "$TMPFILE" "$GNUPLOT_SCRIPT"
}
    
# Clean up old backups by removing older tarballs or directories.
clean() {
    echo "not implemented yet, remove old tarballs and incremental backups manually"
}

#--------------------------------------------------------------------------------------------

# script entrypoint
#read command line arguments
if [ "$1" == "backup" ]; then
    check_root
    # read next argument for backup type
    if [ -z "$2" ]; then
        echo "Please specify the backup type: full or incremental."
        exit 1
    fi
    if [ "$2" == "full" ]; then
        echo "Performing full backup..."
        backup_full
    elif [ "$2" == "incremental" ]; then
        echo "Performing incremental backup..."
        backup_incremental
    else
        echo "Invalid backup type specified. Use 'full' or 'incremental'."
        exit 1
    fi
elif [ "$1" == "clean" ]; then
    check_root
    clean
elif [ "$1" == "analysis" ]; then
    # read next argument for analysis type
    if [ -z "$2" ]; then
        echo "Please specify the analysis type: full or incremental."
        exit 1
    fi
    if [ "$2" == "full" ]; then
        echo "Performing analysis on full backups..."
        analysis_full
    elif [ "$2" == "incremental" ]; then
        echo "Performing analysis on incremental backups..."
        analysis_incremental
    else
        echo "Invalid analysis type specified. Use 'full' or 'incremental'."
        exit 1
    fi

else
    echo "Usage: $0 {backup|clean|analysis} [full|incremental]"
    echo "  backup: Perform a backup (full or incremental)"
    echo "  clean: Clean up old backups"
    echo "  analysis: Analyze backup data (full or incremental)"
    exit 1
fi
