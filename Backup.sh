#!/usr/bin/env bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# ---------------------------------------------------------------------------------------------------------------
# Backup_pi - Raspberry Pi image and user backup script using image-backup and PiShrink
# Location: /usr/local/bin/Backup.sh (Symlinked to ~/Installs/Backup_pi/Backup.sh)
#               (sudo ln -s /user/pi/Installs/Backup_pi/Backup.sh /usr/local/bin/Backup.sh )
# Scheduled: 23:59 Daily via /etc/crontab
#               (sudo nano /etc/crontab  )
#                (ADD: 59 23   * * *   root    /bin/bash /usr/local/bin/Backup.sh >> /var/log/Backup_pi.log 2>&1 )
#                                       ( You might need to create the Backup_pi.log file first...)
#
#    FIX:
# 
#            # MARKER_FILE  COULD BE:  "$BACKUP_ROOT/.USB_IS_HERE"
#
# ----------------------------------------------------------------------------------------------------------------
#

# Set for true exit code when using a piped commands
set -o pipefail

# Check if run as sudo or re-start it if it was not
if [[ $EUID -ne 0 ]]; then
    echo "Elevating privileges..."
    exec sudo "$0" "$@"
fi

# Arrays to keep track of different mount types
FSTAB_MOUNTS=()
declare -a MANUAL_MOUNTS
declare -a MANUAL_PATHS  # New array for clean paths

# The Flags: starts as "false"
DRIVES_ARE_UNMOUNTED=false
SERVICES_STOPPED=false
DOCKER_CONTAINERS_STOPPED=false

check_commands() {
    local MISSING=0
    # Loop through every command name you pass to the function
    for cmd_input in "$@"; do
        local IS_OPTIONAL=0
        local cmd="$cmd_input"

        # 1. Check if it starts with '?' (Our "Optional" marker)
        if [[ "$cmd" == "?"* ]]; then
            IS_OPTIONAL=1
            cmd="${cmd#?}" # Strip the '?' for the actual check
        fi

        local path
        path=$(command -v "$cmd")
        
        if [[ -n "$path" ]]; then
            # 2. Create the variable (e.g., PISHRINK_BIN)
            local var_name
            var_name=$(echo "${cmd%.*}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')_BIN
            declare -g "$var_name"="$path"
        else
            if [[ "$IS_OPTIONAL" -eq 1 ]]; then
                echo "Notice: Optional tool '$cmd' not found. Disabling feature." | do_log
            else
                # echo "CRITICAL: Required tool '$cmd' not found!" | do_log
                # exit 1 # Hard stop only for required tools
                echo "Error: Required command '$cmd' not found in PATH." | do_log
                MISSING=$((MISSING + 1))
            fi
        fi
    done
    # If any mission-critical commands are missing, you might want to exit
    if (( MISSING > 0 )); then
        echo "Total missing commands: $MISSING. Please install them." | do_log
        exit 1 # Optional: Uncomment to stop the script if tools are missing
    fi
}

# OS codename - used for backup filename and folder structure
get_codename() {
    local VERSION_CODENAME
    VERSION_CODENAME=$(bash -c '. /etc/os-release; echo $VERSION_CODENAME' | sed 's/.*/\u&/')
    echo "$VERSION_CODENAME"
}

# Ensure log folder structure exists, try to create it
log_directory_check() {
    echo "Checking for log directory: ${LOG_TO_FILE_DIRECTORY} and creating if missing"
    [ ! -d "$LOG_TO_FILE_DIRECTORY" ] && mkdir -p "$LOG_TO_FILE_DIRECTORY"
    echo ""
}

# Check if external log file is enabled and if so tee to that file (and std output also)
do_log() {
    # Combine them here once to ensure the path is clean
    local LOG_PATH="${LOG_TO_FILE_DIRECTORY}/${LOG_TO_FILE_FILENAME}"

    if [[ "$LOG_TO_FILE" == "1" ]]; then
        tee -a "$LOG_PATH"
    else
        cat # Just passes the text through without saving to a file
    fi
}

# Ensure backup folder structure exists, try to create it
directory_check() {
    echo "Checking for backup directory:  ${BACKUP_PATH} and creating if missing" | do_log
    echo "" | do_log
    [ ! -d "$BACKUP_PATH" ] && mkdir -p "$BACKUP_PATH"
}

# 1. FIND AND ANALYZE THE CUSTOM MOUNTS
find_custom_mounts() {
    echo "Checking for custom mounts..."
    # Get the array of mounts not part of the OS (using excluded folders)
    local targets
    targets=$(findmnt --real -nlo TARGET | grep -vE "^/(boot|media|mnt|srv|opt|var|dev|proc|sys)?(/|$)")

    # local targets=$(findmnt --real -nlo TARGET | grep -vE "^/(boot|media|mnt|srv|opt|var|dev|proc|sys)?(/|$)")

    if [ -z "$targets" ]; then

        echo "No custom mounts found." | do_log
        echo "" | do_log
        return
    fi

    for mnt in $targets; do

        # Check if the mount exists in fstab
        if findmnt --fstab --target "$mnt" >/dev/null 2>&1; then
            FSTAB_MOUNTS+=("$mnt")
            echo "Found fstab mount: $mnt" | do_log
        else # Not in fstab! Save its live mount command details
            # FIRST ENSURE THE .smbcredentials file exists
            # Define the expected path to the credentials file
            CREDS_FILE="$SCRIPT_DIR/.smbcredentials"

            # Verify the file exists and is not empty
            if [[ ! -f "$CREDS_FILE" ]]; then
                echo "❌ ERROR: Credentials file missing at $CREDS_FILE" | do_log
                exit 1
            elif [[ ! -s "$CREDS_FILE" ]]; then
                echo "❌ ERROR: Credentials file at $CREDS_FILE is empty" | do_log
                exit 1
            fi

            # echo "✅ Credentials file verified."
            # We need: Source (device), FSType, and Options
            local src
            local typ
            local opt
            src=$(findmnt -nlo SOURCE "$mnt")
            typ=$(findmnt -nlo FSTYPE "$mnt")
            opt=$(findmnt -nlo OPTIONS "$mnt")

            # Re-inject credentials for CIFS
            if [[ "$typ" == "cifs" ]]; then
                # Clean up potential duplicate 'user' tags findmnt might show
                # This catches 'user=' OR 'username='
                opt=$(echo "$opt" | sed -E 's/user(name)?=[^,]*//g; s/password=[^,]*//g; s/,,/,/g')
                # # Finds the home directory of the person who typed 'sudo'
                # local real_home
                # real_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
                # opt="credentials=${real_home:-$HOME}/.smbcredentials,$opt"
                # opt="credentials=$HOME/.smbcredentials,$opt"
                # SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
                opt="credentials=$SCRIPT_DIR/.smbcredentials,$opt"
            fi
            # MANUAL_MOUNTS+=("sudo mount -t $typ -o \"$opt\" \"$src\" \"$mnt\"") # "$mnt|$info")
            MANUAL_MOUNTS+=("sudo mount -t $typ -o \"$opt\" \"$src\" \"$mnt\"")
            MANUAL_PATHS+=("$mnt") # Save the clean path here
            echo "Found custom mount: $mnt   with Source: $src  Type: $typ  Options: $opt" | do_log
        fi
        echo "" | do_log
    done

}

# 2. UNMOUNT FUNCTION
unmount_custom_mounts() {

    for mnt in "${FSTAB_MOUNTS[@]}"; do
        DRIVES_ARE_UNMOUNTED=true
        echo "Attempting to unmount $mnt..." | do_log
        # timeout 10s: If it's busy, it stops trying after 10 seconds
        # sudo umount -l: "Lazy" unmount detaches it now, cleans up later
        if sudo timeout 10s umount -l "$mnt"; then
            echo "Successfully detached fstab mount:  $mnt" | do_log
        else
            echo "Warning: $mnt is very busy. Lazy unmount initiated." | do_log
        fi

        # Give the system a split second to settle
        sleep 1

        # Check if the folder is empty
        if [ -z "$(ls -A "$mnt" 2>/dev/null)" ]; then
            echo "✅ Confirmed: $mnt is empty and unmounted." | do_log
            DRIVES_ARE_UNMOUNTED=true
        else
            echo "⚠️ ALERT: $mnt STILL HAS FILES!" | do_log
            echo "These might be 'ghost files' sitting on your SD card." | do_log
            echo "" | do_log
            # Optional: exit 1  <-- You could stop the backup here for safety
        fi
        # We successfully (or lazily) unmounted at least one drive
        DRIVES_ARE_UNMOUNTED=true
    done

    # Extract the mount point (the last 'word') from each command in the array
    # for cmd in "${MANUAL_MOUNTS[@]}"; do
    # Use the index to keep the command and path synced
    for i in "${!MANUAL_PATHS[@]}"; do
        local mnt="${MANUAL_PATHS[$i]}"
        local cmd="${MANUAL_MOUNTS[$i]}"
        DRIVES_ARE_UNMOUNTED=true
        # This grabs the last argument of the saved command
        # local mnt=$(echo "$cmd" | awk '{print $NF}' | tr -d '"')
        # Bulletproof Move 2: Space-safe way to get the mount point
        # Instead of awk, we extract it from the command we just built
        # local mnt=$(echo "$cmd" | grep -oP '(?<=" )/[^"]+(?=")')
        # If the regex is too complex, just use the 'mnt' you had during the find phase

        echo "Attempting to unmount $mnt..." | do_log
        # timeout 10s: If it's busy, it stops trying after 10 seconds
        # sudo umount -l: "Lazy" unmount detaches it now, cleans up later
        if sudo timeout 10s umount -l "$mnt"; then
            echo "Successfully detached manual mount: $mnt" | do_log
        else
            echo "Warning: $mnt is very busy. Lazy unmount initiated." | do_log
        fi
        
        # Give the system a split second to settle
        sleep 1

        # Check if the folder is empty
        # if [ -z "$(ls -A "$mnt" 2>/dev/null)" ]; then
        # Bulletproof Move 3: Sudo check for ghost files
        if [ -z "$(sudo ls -A "$mnt" 2>/dev/null)" ]; then
            echo "✅ Confirmed: $mnt is empty and unmounted." | do_log
            DRIVES_ARE_UNMOUNTED=true
        else
            echo "⚠️ ALERT: $mnt STILL HAS FILES!" | do_log
            echo "These might be 'ghost files' sitting on your SD card." | do_log
            # Optional: exit 1  <-- You could stop the backup here for safety
        fi

        # We successfully (or lazily) unmounted at least one drive
        DRIVES_ARE_UNMOUNTED=true
        echo "" | do_log
    done

}

# 3. RE-MOUNT
remount_custom_mounts() {

    # A. Remount everything from fstab (simple)
    echo "Restoring fstab mounts..." | do_log
    sudo mount -a
    echo "" | do_log

    # B. Manually remount the ones that weren't in fstab
    if [ ${#MANUAL_MOUNTS[@]} -eq 0 ]; then
        echo "No manual mounts to restore." | do_log
        echo "" | do_log
        DRIVES_ARE_UNMOUNTED=false
        return
    fi

    echo "" | do_log
    echo "Restoring mounts from memory..."
    for cmd in "${MANUAL_MOUNTS[@]}"; do
        echo "Running: $cmd" | do_log
        eval "$cmd"
        # Grab the mount point from the end of the command
        local mnt
        mnt=$(echo "$cmd" | awk '{print $NF}' | tr -d '"')

        # VERIFICATION: Check if the directory is readable and NOT empty
        # (ls -A returns true if there is at least one file/folder inside)
        if [ -d "$mnt" ] && [ "$(sudo ls -A "$mnt")" ]; then
            echo "✅ Verified: $mnt is back online." | do_log
        else
            echo "⚠️ Warning: $mnt appears empty. Remount might have failed." | do_log
        fi
        echo "" | do_log
    done
    DRIVES_ARE_UNMOUNTED=false
}

# This function runs automatically when the script finishes or is interrupted (Ctrl+C)
cleanup() {
    # Only run the remount if the flag was switched to "true"
    if [ "$DRIVES_ARE_UNMOUNTED" = true ]; then
        echo "Script finished or interrupted. Ensuring drives are remounted..." | do_log
        remount_custom_mounts
    else
        echo "Cleanup: No unmounted drives to restore." | do_log
        echo "" | do_log
    fi
    if [ "$SERVICES_STOPPED" = true ] || [ "$DOCKER_CONTAINERS_STOPPED" = true ]; then
        startServices
    fi

}

# Triggers on Exit, Ctrl+C (INT), and Terminal closure (TERM)
trap cleanup EXIT INT TERM

# Send messages as set in config
send_messages() {
    # $1 is the first thing you pass to the function (your message)
    local MSG="$1"

    # 1. Telegram Logic
    if [[ "$SEND_TELEGRAM_MESSAGES" == "1" && ( -n "$TELEGRAM_SEND_GROUP_TOPIC_BIN" || -n "$TELEGRAM_SEND_BIN" ) ]]; then
        if [[ -n "$TELEGRAM_SEND_GROUP_TOPIC_BIN" ]]; then
            # Use "5" as your default topic ID since it's hardcoded in your example
            "$TELEGRAM_SEND_GROUP_TOPIC_BIN" "$MSG" "5" | do_log
        else
            "$TELEGRAM_SEND_BIN" "$MSG" | do_log
        fi
    fi

    # 2. Gotify Logic
    if [[ "$SEND_GOTIFY_MESSAGES" == "1" && -n "$GOTIFY_SEND_BIN" ]]; then
        # Uses your sourced title and priority variables
        "$GOTIFY_SEND_BIN" "$GOTIFY_MESSAGE_TITLE" "$MSG" "$GOTIFY_MESSAGE_PRIORITY" | do_log
    fi

    # 2. Ntfy Logic
    if [[ "$SEND_NTFY_MESSAGES" == "1" && -n "$NTFY_SEND_BIN" ]]; then
        # Uses your sourced title and priority variables
        "$NTFY_SEND_BIN" "$MSG" "$SEND_NTFY_TOPIC" | do_log
    fi
}

send_log_messages() {
    # 1. First, check the Master "Send Logs" Switch
    [[ "$SEND_LOG_MESSAGES" != "1" ]] && return 0

    local TITLE="Backup Log from $HOSTNAME"
    local LINE_COUNT
    LINE_COUNT=$(wc -l < "$FULL_LOG_PATH")

    # 2. Telegram: Send the actual FILE
    if [[ "$SEND_TELEGRAM_MESSAGES" == "1" && ( -n "$TELEGRAM_SEND_GROUP_TOPIC_FILE_BIN" || -n "$TELEGRAM_SEND_BIN" ) ]]; then
        if [[ -n "$TELEGRAM_SEND_GROUP_TOPIC_FILE_BIN" ]]; then
            "$TELEGRAM_SEND_GROUP_TOPIC_FILE_BIN" "$TITLE" "5" "$FULL_LOG_PATH" | do_log
        else
            "$TELEGRAM_SEND_BIN" --file "$FULL_LOG_PATH" --caption "$TITLE"
        fi
    fi

    # 3. Gotify: Send the FORMATTED SNIPPET (If log is more than 200 lines)
    if [[ "$SEND_GOTIFY_MESSAGES" == "1" && -n "$GOTIFY_SEND_BIN" ]]; then
        local GOTIFY_MSG

        if [[ "$LINE_COUNT" -le 200 ]]; then
            # File is short: send the whole thing
            GOTIFY_MSG=$(cat "$FULL_LOG_PATH")
        else
            local START_LOG
            local END_LOG

            START_LOG=$(head -n 100 "$FULL_LOG_PATH")
            END_LOG=$(tail -n 100 "$FULL_LOG_PATH")

            # SNIPPET=$(printf -- "--- FIRST 100 LINES ---\n%s\n\n--- [... SNIP ...] ---\n\n--- LAST 100 LINES ---\n%s" "$START_LOG" "$END_LOG")
            GOTIFY_MSG=$(printf -- "--- FIRST 100 LINES ---\n%s\n\n--- [... SNIP ...] ---\n\n--- LAST 100 LINES ---\n%s" "$START_LOG" "$END_LOG")
        fi
        "$GOTIFY_SEND_BIN" "$GOTIFY_MESSAGE_TITLE" "$GOTIFY_MSG" "$GOTIFY_MESSAGE_PRIORITY" | do_log
    fi

    # 4. Nfty: Send the actual FILE
    if [[ "$SEND_NTFY_MESSAGES" == "1" && -n "$NTFY_SEND_FILE_BIN" ]]; then
        "$NTFY_SEND_FILE_BIN" "$TITLE" "$SEND_NTFY_TOPIC" "$FULL_LOG_PATH" | do_log
    fi
}

stopServices() {
    if [[ "$STOP_CONTAINERS" == "0" && "$STOP_SERVICES" == "0" ]]; then
        return 0
    fi
    echo "Stopping Docker containers and services before backup..." | do_log
    echo | do_log
    if [[ "$STOP_CONTAINERS" == "1" ]]; then
        # Check if the variable is NOT blank before starting
        if [[ -n "$DOCKER_CONTAINERS" ]]; then
            echo "Stopping containers: $DOCKER_CONTAINERS" | do_log

            # Loop through each item in the space-separated string
            for container in $DOCKER_CONTAINERS; do
                echo "Processing: $container..." | do_log
                docker stop "$container" >/dev/null
                DOCKER_CONTAINERS_STOPPED=true
            done

            echo "All containers specified to be stopped have been processed." | do_log
            echo | do_log
        else
            echo "Error: DOCKER_CONTAINERS is empty or not defined." | do_log
            echo | do_log
        fi
    fi
    if [[ "$STOP_SERVICES" == "1" ]]; then
        # Check if the variable is NOT blank before starting
        if [[ -n "$SERVICES_RUNNING" ]]; then
            echo "Stopping Services: $SERVICES_RUNNING" | do_log

            # Loop through each item in the space-separated string
            for services in $SERVICES_RUNNING; do
                echo "Processing: $services..." | do_log
                systemctl stop "$services" | do_log
                SERVICES_STOPPED=true
            done

            echo "All services specified to be stopped have been processed." | do_log
            echo | do_log
        else
            echo "Error: SERVICES_RUNNING is empty or not defined." | do_log
            echo | do_log
        fi
    fi
    sync
}

startServices() {
    if [[ "$STOP_CONTAINERS" == "0" && "$STOP_SERVICES" == "0" ]]; then
        return 0
    fi
    echo "Starting the stopped services and Docker containers..." | do_log
    echo | do_log
    # 1. Convert the strings into a temporary array
    # shellcheck disable=SC2206
    services=($SERVICES_RUNNING)
    # shellcheck disable=SC2206
    containers=($DOCKER_CONTAINERS)
    if [[ "$STOP_SERVICES" == "1" ]]; then
        # Check if the variable is NOT blank before starting
        if [[ -n "$SERVICES_RUNNING" ]]; then
            echo "Re-starting Services: $SERVICES_RUNNING" | do_log
            # 2. Loop through the array indices in reverse
            # Starting at (total length - 1) down to 0
            for ((i = ${#services[@]} - 1; i >= 0; i--)); do
                service="${services[$i]}"
                echo "Starting: $service" | do_log
                systemctl start "$service" | do_log
            done
            SERVICES_STOPPED=false
            echo "All services stopped prior to the backup have been restarted." | do_log
            echo | do_log
        else
            echo "Error: SERVICES_RUNNING is empty or not defined." | do_log
            echo | do_log
        fi
    fi
    if [[ "$STOP_CONTAINERS" == "1" ]]; then
        # Check if the variable is NOT blank before starting
        if [[ -n "$DOCKER_CONTAINERS" ]]; then
            echo "Starting containers: $DOCKER_CONTAINERS" | do_log

            # 2. Loop through the array indices in reverse
            # Starting at (total length - 1) down to 0
            for ((i = ${#containers[@]} - 1; i >= 0; i--)); do
                container="${containers[$i]}"
                echo "Starting: $container" | do_log
                docker start "$container" >/dev/null
            done
            DOCKER_CONTAINERS_STOPPED=false
            echo "All containers specified to be stopped have been restarted." | do_log
            # echo | do_log
        else
            echo "Error: DOCKER_CONTAINERS is empty or not defined." | do_log
        fi
    fi
    echo | do_log
}

# Find latest .img file in currenly defined backup path
find_incremental_file() {
    local LATEST_INCREMENTAL
    LATEST_INCREMENTAL=$(bash -c "find ${BACKUP_PATH}/${HOSTNAME}-${OS_NAME}-${ARCHITECTURE}-*.img -type f | sort -n | cut -d ' ' -f 2- | tail -n 1")
    if [[ -z "$LATEST_INCREMENTAL" ]]; then
        echo "Incremental backup selected but no existing image file found to update... Terminating." | do_log
        exit 1
    fi
    LATEST_INCREMENTAL_FILENAME=$(basename "$LATEST_INCREMENTAL") #  or: filename="${src_file##*/}"  (faster)
    echo "$LATEST_INCREMENTAL_FILENAME"
}

# --- Function to scrub CSV strings to remove progress options for CRON jobs (e.g. "--progress,--stats,--exclude") ---
scrub_csv() {
    local input=$1
    local IFS=','
    local -a parts
    read -ra parts <<<"$input"
    local -a kept=()

    for part in "${parts[@]}"; do
        # Skip if it contains "progress"
        [[ "$part" == *progress* ]] && continue
        kept+=("$part")
    done

    # Join back with commas and echo
    echo "$(
        IFS=,
        echo "${kept[*]}"
    )"
}

rotate_backups_and_logs() {
    local PATTERN="$1"
    local LIMIT="$2"
    local DESC="$3"

    # 1. Get the list of all matches, sorted alphabetically (Oldest at top)
    local ALL_BACKUPS
    # shellcheck disable=SC2012
    ALL_BACKUPS=$(ls -1d "${PATTERN}"* 2>/dev/null | sort)

    # 2. Count them (ignoring empty results)
    local TOTAL_FILES
    TOTAL_FILES=$(echo "$ALL_BACKUPS" | grep -vc '^$')

    if (( TOTAL_FILES > LIMIT )); then
        local NUM_TO_DELETE=$(( TOTAL_FILES - LIMIT ))
        local PURGE_LIST
        PURGE_LIST=$(echo "$ALL_BACKUPS" | head -n "$NUM_TO_DELETE")
        
        echo "Rotation ($DESC): Found $TOTAL_FILES. Keeping $LIMIT newest." | do_log
        echo "$PURGE_LIST" | while read -r item; do
            echo "  - Removing: $item" | do_log
            rm -rf -- "$item" 2>&1 | do_log
        done

    else
        echo "Rotation ($DESC): Nominal. No purges required." | do_log
    fi
}

# Get the directory where the script is located
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
CONFIG_FILE="$SCRIPT_DIR/Backup.conf"

# Check if the config file exists before trying to load it
if [[ -f "$CONFIG_FILE" ]]; then
    # The dot (.) is the command for 'source'
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
else
    echo "ERROR: Configuration file $CONFIG_FILE not found!" | do_log
    exit 1
fi
# Convert the IMAGE_BACKUP_OPTIONS string from the config into a real Bash array
read -r -a IMAGE_BACKUP_OPTIONS_ARRAY <<<"$IMAGE_BACKUP_OPTIONS"

# SETTINGS IN Backup.conf :
# Type can be - "image" / "image incremental" / "user" / "user compressed"
# BACKUP_TYPE="image incremental"
# BACKUP_ROOT="/media/usb0/Backups/
# MARKER_FILE="/media/usb0/Backups/.USB_IS_HERE"
# LOG_TO_FILE=1
# LOG_TO_FILE_DIRECTORY="/home/pi/Installs/Backup_pi/log"
# --- Mounts can be unmounted prior to backup (then re-mounted after)
# UNMOUNT_CUSTOM_MOUNTS_PRIOR_TO_BACKUP=0
# --- Services and Docker containers to stop & re-start
# STOP_SERVICES=1
# STOP_CONTAINERS=1
# A space-separated list of container names or IDs
# DOCKER_CONTAINERS="netdata pihole dnscrypt-proxy portainer"
# A space-separated list of Services
# SERVICES_RUNNING="smbd docker.socket docker tailscaled"
# --- Messaging options ---
# SEND_TELEGRAM_MESSAGES=1
# SEND_GOTIFY_MESSAGES=1
# SEND_NTFY_MESSAGES=1
# SEND_NTFY_TOPIC="TTsPlaceSF-host01-status"
# SEND_MESSAGES_ONLY_ON_ERROR=0
# SEND_CONFIRMATON_MESSAGE_ONLY=0
# SEND_LOG_MESSAGES=1
# --- Limits & Retention ---
# BACKUP_ANTAL=7
# USER_BACKUP_ANTAL=30
# LOG_ANTAL=30
# --- Backup "image-backup" & (-o rsync,options) ---
# IMAGE_BACKUP_OPTIONS="-n -o --info=progress2,--stats"
# IMAGE_BACKUP_INITIAL_IMAGE_SIZE=
# IMAGE_BACKUP_ADDITIONAL_IMAGE_SPACE_FOR_INCREMENTAL_BACKUPS=5000   # 5 GB (or so)
# --- Post Image creation options ---
# VERIFY_IMAGE=1
# PISHRINK_IMAGE=0
# PISHRINK_AND_GZIP_IMAGE=0

# Get hostname of system
HOSTNAME=$(hostname -s)
# Get codename of OS
VERSION_CODENAME=$(get_codename)
# Add hostname / OS codename to backup path
BACKUP_PATH="${BACKUP_ROOT}/${HOSTNAME}/${VERSION_CODENAME}"
# Save date and time to add to filename
BACKUP_DATO=$(date "+%F@%H-%M-%S")

# Detect Architecture (32 vs 64) - for filename
BITS=$(getconf LONG_BIT)
ARCHITECTURE="${BITS}bits"

# Detect OS Codename (fallback if necessary)
if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_NAME=$VERSION_CODENAME
    # Fallback for older versions that don't use VERSION_CODENAME
    [ -z "$OS_NAME" ] && OS_NAME=$(echo "$VERSION" | grep -oE '[a-z]+' | head -1)
else
    OS_NAME="unknown"
fi

# Define Gotify message variables
GOTIFY_MESSAGE_TITLE="${HOSTNAME} Nightly Backup status"
GOTIFY_MESSAGE_PRIORITY=5

# Default behavior: Full Image
BACKUP_MODE="FULL"
COMPRESS_USER="FALSE"

# If run with sudo, get the original user; otherwise, get current user
REAL_USER=${SUDO_USER:-$(whoami)}
USER_DIR="/home/$REAL_USER"

# Check for flags - THESE TAKE PRESIDENCE OVER ANY IMAGE BACKUP
# The  command line Flag Parser (added 'c')
while getopts "uci" opt; do
    case $opt in
    u) BACKUP_MODE="USER" ;;
    c) COMPRESS_USER="TRUE" ;;
    i) FORCED_INITIAL="TRUE" ;;
    *) echo "Usage: $0 [-u] [-c] [-i]" && exit 1 ;;
    esac
done
# --- The "Mutual Exclusion" Check ---
# If -i is TRUE, check if -u or -c were also set
if [[ "$FORCED_INITIAL" == "TRUE" ]]; then
    if [[ "$BACKUP_MODE" == "USER" || "$COMPRESS_USER" == "TRUE" ]]; then
        echo "Error: The -i flag cannot be used with -u or -c."
        echo "Usage: $0 [-u -c] OR [-i]"
        exit 1
    fi
fi

# BACKUP_MODE selection...
if [[ ("$BACKUP_TYPE" == "user" || ("$BACKUP_MODE" == "USER" && "$COMPRESS_USER" != "TRUE")) && "$FORCED_INITIAL" != "TRUE" ]]; then
    BACKUP_MODE="USER"
    START_MSG="Initiating UNCOMPRESSED User Backup (-u) for $REAL_USER"
    # Re-Set log filename using user directory
    LOG_TO_FILE_FILENAME="user_files_${REAL_USER}_${BACKUP_DATO}.log"

elif [[ ("$BACKUP_TYPE" == "user compressed" || "$COMPRESS_USER" == "TRUE") && "$FORCED_INITIAL" != "TRUE" ]]; then
    BACKUP_MODE="USER"
    COMPRESS_USER="TRUE"
    START_MSG="Initiating COMPRESSED User Backup (-uc) for $REAL_USER to: user_backup_${REAL_USER}_${BACKUP_DATO}.tar.gz"
    # Re-Set log filename using user directory
    LOG_TO_FILE_FILENAME="user_backup_${REAL_USER}_${BACKUP_DATO}.tar.gz.log"

elif [[ "$BACKUP_TYPE" == "image incremental" && "$FORCED_INITIAL" != "TRUE" ]]; then
    BACKUP_MODE="IMAGE INCREMENTAL"
    FILENAME=$(find_incremental_file)
    START_MSG="INCREMENTAL IMAGE Backup on $HOSTNAME to: $FILENAME at $(date)"
    LOG_TO_FILE_FILENAME="Backup_pi-${FILENAME}.log"

else
    FILENAME="${HOSTNAME}-${OS_NAME}-${ARCHITECTURE}-${BACKUP_DATO}.img"
    if [[ "$PISHRINK_AND_GZIP_IMAGE" == "1" && "$FORCED_INITIAL" != "TRUE" ]]; then #  PISHRINK_AND_GZIP_IMAGE
        START_MSG="FULL SYSTEM IMAGE Backup on $HOSTNAME to: $FILENAME.gz at $(date)"
        LOG_TO_FILE_FILENAME="Backup_pi-${FILENAME}.gz.log"
    else
        START_MSG="FULL SYSTEM IMAGE Backup on $HOSTNAME to: $FILENAME at $(date)"
        LOG_TO_FILE_FILENAME="Backup_pi-${FILENAME}.log"
    fi
    BACKUP_MODE="IMAGE"
fi
# SET full backup path
FULL_PATH="${BACKUP_PATH}/${FILENAME}"

# IF logging is selected then set full log path
if [[ "$LOG_TO_FILE" == "1" ]]; then
    # Combine the directory and filename into one quoted string for safety
    FULL_LOG_PATH="$LOG_TO_FILE_DIRECTORY/$LOG_TO_FILE_FILENAME"
fi

# Check for necessary commands and when found read full path of command into a variable like $RSYNC_BIN (? in front of optional commands)
check_commands rsync fstrim image-backup image-info "?pishrink.sh" "?telegram-send" "?telegram-send-group-topic.sh" "?telegram-send-group-topic-file.sh" "?gotify-send.sh" "?ntfy-send.sh" "?ntfy-send-file.sh"
# NOT STRICTLY NECESSARY IF NOT USED - pishrink.sh telegram-send-group-topic.sh telegram-send-group-topic-file.sh gotify-send.sh ntfy-send.sh ntfy-send-file.sh
# echo "$RSYNC_BIN"
# echo "$FSTRIM_BIN"
# echo "$IMAGE_BACKUP_BIN"
# echo "$IMAGE_INFO_BIN"
# echo "$PISHRINK_BIN"
# echo "$TELEGRAM_SEND_BIN"
# echo "$TELEGRAM_SEND_GROUP_TOPIC_BIN"
# echo "$TELEGRAM_SEND_GROUP_TOPIC_FILE_BIN"
# echo "$GOTIFY_SEND_BIN"
# echo "$NTFY_SEND_BIN"
# echo "$NTFY_SEND_FILE_BIN"
# exit 0

# Define the source device (SD card or USB)
if [ -b "/dev/mmcblk0" ]; then
    SOURCE_DEV="/dev/mmcblk0"
else
    SOURCE_DEV="/dev/sda"
fi

# Print a separator and timestamp to the terminal, then log
echo "---------------------------------------------------"
echo "Backup started at: $(date)"
echo "System Detected: $OS_NAME ($ARCHITECTURE)"
echo "Device to back up: $SOURCE_DEV"
echo "Type: $START_MSG"
if [[ "$LOG_TO_FILE" == "1" ]]; then
    echo "Log file: $FULL_LOG_PATH"
fi
echo ""
if [[ "$LOG_TO_FILE" == "1" ]]; then
    log_directory_check
    if [[ "$BACKUP_MODE" == "IMAGE INCREMENTAL" ]]; then
        {
            echo "---------------------------------------------------"
            echo "----------------INCREMENTAL UPDATE-----------------"
            echo "---------------------------------------------------"
        } >>"$FULL_LOG_PATH"
    else
        echo "---------------------------------------------------" >"$FULL_LOG_PATH"
    fi
    {
        echo "Backup started at: $(date)"
        echo "System Detected: $OS_NAME ($ARCHITECTURE)"
        echo "Device to back up: $SOURCE_DEV"
        echo "Type: $START_MSG"
        echo "Log file: ""$LOG_TO_FILE_DIRECTORY"/"$LOG_TO_FILE_FILENAME"""
        echo "" 
    } >>"$FULL_LOG_PATH"
fi

# Send start message if set to send messages and not restricted to some messages only
if [[ "$SEND_MESSAGES_ONLY_ON_ERROR" != "1" && "$SEND_CONFIRMATON_MESSAGE_ONLY" != "1" ]]; then
    send_messages "🚀 BEGINNING: $START_MSG"
fi
echo "" | do_log

# Check if not user backup - if so set up file for image expanding & trim partitions
if [[ "$BACKUP_MODE" != "USER" ]]; then
    # Ensure /etc/rc.local exists for PiShrink
    if [[ ! -f /etc/rc.local ]]; then
        echo "NOTICE: /etc/rc.local missing. Creating for PiShrink and image-backup auto-expand..." | do_log

        # Create the basic script structure
        # Using 'printf' to avoid escape character issues
        printf '%s\n' '#!/bin/bash' '' 'exit 0' | sudo tee /etc/rc.local >/dev/null

        # Make it executable (This is the "trigger" for Systemd)
        sudo chmod +x /etc/rc.local

        # Reload systemd so it notices the new file immediately
        sudo systemctl daemon-reload >/dev/null 2>&1

        echo "SUCCESS: /etc/rc.local created. Expansion code available for injection." | do_log
    fi

    if [[ "$SOURCE_DEV" == "/dev/mmcblk0" ]]; then
        # Clean up unused blocks to make the final image compress better
        echo "Reducing filesize by using fstrim..." | do_log
        echo "" | do_log

        # Identify the VFAT boot partition dynamically
        BOOT_PART=$(lsblk -lno NAME,FSTYPE | grep vfat | awk '{print "/dev/"$1}' | head -n 1)
        TEMP_MOUNT="/mnt/boot_temp"

        # Check if it's already mounted somewhere
        CURRENT_MOUNT=$(findmnt -nvo TARGET "$BOOT_PART")

        if [[ -n "$CURRENT_MOUNT" ]]; then
            # Partition is already mounted (e.g., to /boot/firmware)
            stdbuf -oL "$FSTRIM_BIN" -v "$CURRENT_MOUNT" 2>&1 | do_log
            stdbuf -oL "$FSTRIM_BIN" -v / 2>&1 | do_log
        elif [[ -b "$BOOT_PART" ]]; then
            # Partition needs temporary mounting
            mkdir -p "$TEMP_MOUNT"
            echo "Boot partition not mounted. Mounting temporarily..." | do_log
            echo "" | do_log
            if mount "$BOOT_PART" "$TEMP_MOUNT"; then
                stdbuf -oL "$FSTRIM_BIN" -v "$TEMP_MOUNT" 2>&1 | do_log
                sleep 1
                umount "$TEMP_MOUNT"
            fi
            # Always trim root last
            stdbuf -oL "$FSTRIM_BIN" -v / 2>&1 | do_log
        else
            echo "Warning: Could not identify a VFAT boot partition. Trimming root only." | do_log
            stdbuf -oL "$FSTRIM_BIN" -v / 2>&1 | do_log
        fi
        echo "" | do_log
    fi
fi

# Verify the backup drive is actually mounted
# This looks for a "Marker file" in the root of the backup path (as defined in .conf)
echo "Checking for backup destination..." | do_log
echo "" | do_log

# Look for marker file existence - means backup destination is available
if [ ! -f "$MARKER_FILE" ]; then
    echo "ERROR: Marker file $MARKER_FILE not found! The USB drive might be unmounted. Aborting to save SD card space." | do_log
    echo "" | do_log

    # # send error notifications
    send_messages "❌ Backup FAILED for $HOSTNAME. BACKUP USB DRIVE NOT FOUND. Check Backup_pi.log"
    send_log_messages
    exit 1
fi

# Must have found marker file - proceed with backup
echo "USB Marker found. Proceeding with backup..." | do_log
echo "" | do_log

directory_check # Make sure backup directory exists on backup drive

# # NOT USED - This checks if the backup path lives on the same drive as the OS (/)
# # If they are the same, it means the USB isn't mounted.
# if [ "$(stat -c%d /)" = "$(stat -c%d "$BACKUP_PATH")" ]; then
#     echo "ERROR: $BACKUP_PATH appears to be on the SD card, not the USB drive! Aborting."
#     exit 1
# fi
# if ! mountpoint -q "$BACKUP_PATH"; then
#     echo "ERROR: Backup destination $BACKUP_PATH is NOT a mountpoint. Aborting to save SD card space."
#     exit 1
# fi

# Resource Check: USB Capacity (90% Threshold)
# Extracts the capacity percentage of the backup mount point
USB_USAGE=$(df "$BACKUP_PATH" | awk 'NR==2 {print $5}' | sed 's/%//')

if [ "$USB_USAGE" -gt 90 ]; then
    WARN_MSG="WARNING: USB Storage at ${USB_USAGE}% capacity! Resources critical."
    echo "$WARN_MSG" | do_log
    echo "" | do_log
    if [[ "$SEND_MESSAGES_ONLY_ON_ERROR" != "1" && "$SEND_CONFIRMATON_MESSAGE_ONLY" != "1" ]]; then
        send_messages "⚠️ $WARN_MSG"
        echo "" | do_log
    fi
    # Optional: exit 1  <-- Add this if you want to abort the backup when full
fi

if [[ "$UNMOUNT_CUSTOM_MOUNTS_PRIOR_TO_BACKUP" == "1" ]]; then
    echo "Checking for custom mounts to unmount prior to starting the backup..." | do_log
    echo "" | do_log
    find_custom_mounts 
    if [ ${#FSTAB_MOUNTS[@]} -gt 0 ] || [ ${#MANUAL_MOUNTS[@]} -gt 0 ]; then
        echo "Unmounting the custom mounts found..." | do_log
        unmount_custom_mounts
        echo "" | do_log
    fi
fi

# START BACKUP PROCESSING - USER BACKUP MODES FIRST
if [[ "$BACKUP_MODE" == "USER" ]]; then
    # 1. Check if the home directory exists before proceeding
    if [[ -d "$USER_DIR" ]]; then
        if [[ "$COMPRESS_USER" == "TRUE" ]]; then
            BACKUP_FILE="${BACKUP_PATH}/user_backup_${REAL_USER}_${BACKUP_DATO}.tar.gz"
            echo "Detected user: $REAL_USER. Backing up to $BACKUP_FILE..." | do_log

            # 1. Create compressed archive (removed -W)
            # Add --ignore-failed-read to bypass permission blocks
            # Run the tar command
            tar -czpf "$BACKUP_FILE" --ignore-failed-read --warning=no-file-changed --one-file-system --exclude="$USER_DIR/.cache" --exclude="$USER_DIR/.local/share/Trash" "$USER_DIR" 2> >(grep -v "Removing leading" >&2) | do_log

            # Capture the exit code of tar (first in the pipe)
            TAR_EXIT=${PIPESTATUS[0]}

            # Now check if it was 0 OR 1
            if [[ $TAR_EXIT -eq 0 || $TAR_EXIT -eq 1 ]]; then
                echo "" | do_log
                # 2. Verify the compressed file integrity
                echo "Verifying archive integrity..." | do_log
                if gunzip -t "$BACKUP_FILE" 2>&1 | do_log; then
                    echo "SUCCESS: Archive is valid and healthy." | do_log
                    # Calculate and log the final size
                    FINAL_SIZE=$(du -sh "$BACKUP_FILE" | awk '{print $1}')
                    echo "COMPLETED: Backup saved to $BACKUP_FILE (Size: $FINAL_SIZE)" | do_log
                    echo "" | do_log
                    MESSAGE="✅ Backup Successful for $HOSTNAME to: $BACKUP_FILE (Size: $FINAL_SIZE)"
                    send_messages "$MESSAGE"
                    echo "" | do_log
                    FINAL_REPORT="🏁 *Backup Mission Debrief* 🏁
                    ---------------------------------
                    👤 User: $REAL_USER
                    📦 Mode: $BACKUP_MODE COMPRESSED
                    📋 File: user_backup_${REAL_USER}_${BACKUP_DATO}.tar.gz
                    📊 Size: $FINAL_SIZE
                    🛡️ Integrity: VERIFIED
                    ---------------------------------"
                    # ⏱️ Time: $DURATION
                    # ♻️ Purge Status: $PURGE_RESULT"

                else
                    echo "CRITICAL ERROR: Archive verification failed!" | do_log
                    exit 1
                fi
            else
                echo "ERROR: Tar command failed during creation." | do_log
                exit 1
            fi
            # Set pattern to search for when purging backups
            BACKUP_PATTERN="user_backup_${REAL_USER}_"
            pushd "${BACKUP_PATH}" >/dev/null || echo "Warning: Could not save current directory" | do_log
            if ((USER_BACKUP_ANTAL > 0)); then
                # # # 1. Identify files to delete (filtering out full system images)
                # For Compressed Files
                rotate_backups_and_logs "$BACKUP_PATTERN" "$USER_BACKUP_ANTAL" "Compressed Backups"
            else
                echo "Warning: USER_BACKUP_ANTAL is 0. Skipping purge to prevent total data loss." | do_log
            fi

            # Set pattern to search for when purging log files
            LOG_PATTERN="user_backup_${REAL_USER}_"
        else
            # --- OPTION B: Straight Copy (Structure Only) ---
            # We use rsync to keep permissions, links, and times intact
            DEST_DIR="${BACKUP_PATH}/user_files_${REAL_USER}_${BACKUP_DATO}"
            echo "Mode: Uncompressed Structure. Target: $DEST_DIR" | do_log
            mkdir -p "$DEST_DIR"

            # -a: archive mode (preserves everything)
            # -v: verbose (so do_log catches the file list)
            "$RSYNC_BIN" -av "$USER_DIR/" "$DEST_DIR/" 2>&1 | do_log
            FINAL_SIZE=$(du -sh "$DEST_DIR" | awk '{print $1}')
            echo "" | do_log
            echo "Backup Successful for $HOSTNAME from: $USER_DIR/ to: $DEST_DIR (Size: $FINAL_SIZE)" | do_log
            echo "" | do_log
            MESSAGE="✅ Backup Successful for $HOSTNAME from: $USER_DIR/ to: $DEST_DIR (Size: $FINAL_SIZE)"
            send_messages "$MESSAGE"
            echo "" | do_log
            FINAL_REPORT="🏁 *Backup Mission Debrief* 🏁
            ---------------------------------
            👤 User: $REAL_USER
            📦 Mode: $BACKUP_MODE
            📁 Folder: user_files_${REAL_USER}_${BACKUP_DATO}
            📊 Size: $FINAL_SIZE
            🛡️ Integrity: VERIFIED
            ---------------------------------"
            # ⏱️ Time: $DURATION
            # ♻️ Purge Status: $PURGE_RESULT"

            # Set pattern to search for when purging backups
            BACKUP_PATTERN="user_files_${REAL_USER}_"
            pushd "${BACKUP_PATH}" >/dev/null || echo "Warning: Could not save current directory" | do_log
            if ((USER_BACKUP_ANTAL > 0)); then
                # # 1. Identify dirs (-d) to delete (filtering out full system images)
                # For User Directories
                rotate_backups_and_logs "$BACKUP_PATTERN" "$USER_BACKUP_ANTAL" "User Directories"
                # echo "" | do_log
            else
                echo "Warning: USER_BACKUP_ANTAL is 0. Skipping purge to prevent total data loss." | do_log
            fi
            # Set pattern to search for when purging log files
            LOG_PATTERN="user_files_${REAL_USER}_"
        fi

        # Purge Logs if selected
        if ((LOG_ANTAL > 0)); then
            # Ensure the directory exists before we try to enter it
            if [[ -d $LOG_TO_FILE_DIRECTORY ]]; then
                pushd "${LOG_TO_FILE_DIRECTORY}" >/dev/null || echo "Warning: Could not save current directory" | do_log

                # For Log Files
                rotate_backups_and_logs "$LOG_PATTERN" "$LOG_ANTAL" "Log Files"

                # Change back to starting directory
                popd >/dev/null || echo "Warning: Could not return to previous directory" | do_log
            fi
        fi
        echo "Rotation complete." | do_log
        echo "" | do_log

        if [ "$DRIVES_ARE_UNMOUNTED" = true ]; then
            # echo "Script finished or interrupted. Ensuring drives are remounted..." | do_log
            remount_custom_mounts
        fi

        send_messages "$FINAL_REPORT"
        if [[ "$LOG_TO_FILE" == "1" ]]; then
            echo "" >>"$FULL_LOG_PATH"
            echo "Backup script execution completed successfully" >>"$FULL_LOG_PATH"
        fi
        send_log_messages
    else
        # Fallback: if the home dir doesn't match the username (rare on Debian)
        echo "ERROR: Could not find home directory for $REAL_USER at $USER_DIR" | do_log
        exit 1
    fi
elif [[ "$BACKUP_MODE" == "IMAGE" ]]; then

    echo "Calculating backup size and checking if destination has enough space for backup..." | do_log

    # Get source size in bytes
    SOURCE_SIZE=$(sudo blockdev --getsize64 "$SOURCE_DEV")

    # Get available space on backup drive in bytes
    # 'df -B1' forces the output into 1-byte blocks for exact math
    AVAIL_SPACE=$(df -B1 --output=avail "$BACKUP_PATH" | tail -n 1)

    #     # Add a 5% safety margin (backup needs to be slightly larger than source)
    #     REQUIRED_SPACE=$(( SOURCE_SIZE + (SOURCE_SIZE / 20) ))

    # # Get the last used sector (works for 1 partition or 10)
    # # We use 'unit s' to get raw sectors for precision
    #
    # 1. Get the last sector and add a safety buffer of 32768 sectors (16MB)
    # This ensures we never miss the end of the filesystem or the GPT backup table
    LAST_SECTOR=$(sudo parted -s "$SOURCE_DEV" unit s print | awk '/^[ ]*[0-9]/ {print $3}' | sed 's/s//' | sort -n | tail -1)
    # TOTAL_SECTORS=$(( LAST_SECTOR + 32768 ))
    #
    # echo "Last Sector: $LAST_SECTOR | Copying up to: $TOTAL_SECTORS" | do_log

    if [ -z "$LAST_SECTOR" ]; then
        echo "ERROR: Could not detect partitions on $SOURCE_DEV. Defaulting to full copy." | do_log
        TOTAL_SECTORS=""
    else
        # # Calculate 1MB blocks: (Sector * 512 / 1024 / 1024)
        # 2. Convert to Megabytes and ROUND UP by adding 16MB of safety buffer
        # This ensures we always land on a clean 1MB boundary that PiShrink can read
        AUTO_COUNT=$(((LAST_SECTOR * 512 / 1048576) + 16))
        # echo "Detected last partition ends at sector $LAST_SECTOR. Optimized count: $AUTO_COUNT" | do_log

        echo "Calculated Count: $AUTO_COUNT (1MB blocks)" | do_log
        # shellcheck disable=SC2034
        TOTAL_SECTORS=$((LAST_SECTOR + 32768))

        echo "Last Sector: $LAST_SECTOR | Copying up to: $AUTO_COUNT" | do_log
    fi

    if [ -n "$LAST_SECTOR" ]; then
        # Calculate exactly how many bytes we will actually copy
        # (Sector + 1) * 512 bytes
        ACTUAL_DATA_BYTES=$(((LAST_SECTOR + 1) * 512))

        # 2. Update your Required Space calculation
        # We use the actual data size instead of the full disk size
        # Adding 5% buffer: ACTUAL_DATA_BYTES + (ACTUAL_DATA_BYTES / 20)
        REQUIRED_SPACE=$((ACTUAL_DATA_BYTES + (ACTUAL_DATA_BYTES / 20)))

        echo "Physical disk is larger, but partitions only use: $((ACTUAL_DATA_BYTES / 1024 / 1024)) MB" | do_log
        echo "Required space (with 5% buffer): $((REQUIRED_SPACE / 1024 / 1024)) MB" | do_log
    else
        # Fallback if parted fails: use the old blockdev method
        SOURCE_SIZE=$(sudo blockdev --getsize64 "$SOURCE_DEV")
        REQUIRED_SPACE=$((SOURCE_SIZE + (SOURCE_SIZE / 20)))
        echo "Warning: Could not detect partitions. Using full disk size for space check." | do_log
    fi

    echo "Source size: $((SOURCE_SIZE / 1024 / 1024 / 1024)) GB" | do_log
    echo "Available space: $((AVAIL_SPACE / 1024 / 1024 / 1024)) GB" | do_log

    echo "Last partition ends at sector: $LAST_SECTOR" | do_log
    echo "Calculated count for 1MB block size: $AUTO_COUNT" | do_log

    if [ "$AVAIL_SPACE" -lt "$REQUIRED_SPACE" ]; then
        echo "ERROR: Not enough space on $BACKUP_PATH!" | do_log
        echo "Required (with margin): $((REQUIRED_SPACE / 1024 / 1024 / 1024)) GB" | do_log
        echo "" | do_log

        if [ "$DRIVES_ARE_UNMOUNTED" = true ]; then
            echo "" | do_log
            remount_custom_mounts
        fi

        # Send error messages if set to do so
        send_messages "❌ Backup FAILED for $HOSTNAME. INSUFFICIENT SPACE ON USB DRIVE. Check Backup_pi.log"

        send_log_messages
        exit 1
    fi
    echo "" | do_log
    echo "Space check passed. Starting backup imaging..." | do_log

    echo "" | do_log

    # Stop services and Docker containers before backup
    stopServices
    if [[ "$STOP_CONTAINERS" == "1" || "$STOP_SERVICES" == "1" ]]; then
        echo "Services stopped..." | do_log
        echo "" | do_log
    fi

    # Run the backup - check if backing up SD card
    if [ -b "/dev/mmcblk0" ]; then
        echo "Backing up SD-Card to $FILENAME..." | do_log

        # Detect if we are running in a terminal (manual) or background (cron)
        if [ -t 1 ]; then
            #  MANUAL: Show a progress bar with Rate, ETA, and Timer
            # 2. Check if the noisy flag is in the array
            IMAGE_BACKUP_LOG_PROGRESS=1
            for opt in "${IMAGE_BACKUP_OPTIONS_ARRAY[@]}"; do
                case "$opt" in
                *progress*)
                    IMAGE_BACKUP_LOG_PROGRESS=0 # Found noisey flag - do not send the noise to the log
                    ;;
                *)
                    # Ignore everything else to our new array
                    ;;
                esac
            done

            echo "Starting image-backup image creation..." | do_log
            echo "" | do_log
            echo "Starting image-backup with command : $IMAGE_BACKUP_BIN $IMAGE_BACKUP_OPTIONS -i $FULL_PATH,$IMAGE_BACKUP_INITIAL_IMAGE_SIZE,$IMAGE_BACKUP_ADDITIONAL_IMAGE_SPACE_FOR_INCREMENTAL_BACKUPS $IMAGE_BACKUP_POST_IMAGE_NAME_OPTIONS" | do_log
            echo "" | do_log
            # Control what is logged so the progress stats do not fill the log
            if [[ "$IMAGE_BACKUP_LOG_PROGRESS" == "1" ]]; then
                # 1. Start the stopwatch
                START_TIME=$SECONDS
                "$IMAGE_BACKUP_BIN" "${IMAGE_BACKUP_OPTIONS_ARRAY[@]}" -i "$FULL_PATH","$IMAGE_BACKUP_INITIAL_IMAGE_SIZE","$IMAGE_BACKUP_ADDITIONAL_IMAGE_SPACE_FOR_INCREMENTAL_BACKUPS" | do_log
                IMAGE_BACKUP_RESULT=$?
            else # Logging and progress requested - skip logging output or the log file is huge
                if [[ "$LOG_TO_FILE" == "1" ]]; then
                    echo "Starting full backup (for incremental backups, run: $IMAGE_BACKUP_BIN $FULL_PATH)" >>"$FULL_LOG_PATH"
                fi
                # 1. Start the stopwatch
                START_TIME=$SECONDS
                "$IMAGE_BACKUP_BIN" "${IMAGE_BACKUP_OPTIONS_ARRAY[@]}" -i "$FULL_PATH","$IMAGE_BACKUP_INITIAL_IMAGE_SIZE","$IMAGE_BACKUP_ADDITIONAL_IMAGE_SPACE_FOR_INCREMENTAL_BACKUPS"
                IMAGE_BACKUP_RESULT=$?
            fi

            # 3. Capture End Stats - Stop the stopwatch
            END_TIME=$SECONDS
            ELAPSED=$((END_TIME - START_TIME))

            # 4. Calculate Average Speed
            # We get the actual file size in bytes and divide by seconds
            FILE_BYTES=$(stat -c%s "$FULL_PATH")
            if [ "$ELAPSED" -gt 0 ]; then
                # Math: (Bytes / 1024 / 1024) / Seconds = MB/s
                AVG_SPEED=$(((FILE_BYTES / 1048576) / ELAPSED))
            else
                AVG_SPEED=0
            fi

            # 5. Format into Hours, Minutes and Seconds (01h:02m:03s)
            # %02d ensures you get '05s' instead of '5s'
            # If hours are 0, it still shows 00h
            DURATION=$(printf '%02dh:%02dm:%02ds' $((ELAPSED / 3600)) $((ELAPSED % 3600 / 60)) $((ELAPSED % 60)))
            echo "" | do_log
            # 3. Use it in your log
            echo "Transfer Performance: ${AVG_SPEED} MB/s average over ${DURATION}" | do_log

        else # CRON job
            # This creates a NEW array excluding the progress flag
            IMAGE_BACKUP_CLEAN_OPTIONS_ARRAY=()
            i=0

            while [[ $i -lt ${#IMAGE_BACKUP_OPTIONS_ARRAY[@]} ]]; do
                opt="${IMAGE_BACKUP_OPTIONS_ARRAY[$i]}"

                case "$opt" in
                -o | --options)
                    # 1. Grab the next element (the values)
                    val="${IMAGE_BACKUP_OPTIONS_ARRAY[$((i + 1))]}"

                    # 2. Scrub the values
                    scrubbed_val=$(scrub_csv "$val")

                    # 3. Only add the flag if something is left after scrubbing
                    if [[ -n "$scrubbed_val" ]]; then
                        IMAGE_BACKUP_CLEAN_OPTIONS_ARRAY+=("$opt" "$scrubbed_val")
                    fi

                    # Move index forward by 2 (the flag and its value)
                    ((i += 2))
                    ;;

                *progress*)
                    # Skip standalone progress flags
                    ((i++))
                    ;;

                *)
                    # Keep everything else
                    IMAGE_BACKUP_CLEAN_OPTIONS_ARRAY+=("$opt")
                    ((i++))
                    ;;
                esac
            done

            echo "Starting image-backup image creation..." | do_log

            echo "Starting image-backup with command : $IMAGE_BACKUP_BIN ${IMAGE_BACKUP_CLEAN_OPTIONS_ARRAY[*]} -i $FULL_PATH" | do_log
            # 1. Start the stopwatch
            START_TIME=$SECONDS
            "$IMAGE_BACKUP_BIN" "${IMAGE_BACKUP_CLEAN_OPTIONS_ARRAY[@]}" -i "$FULL_PATH","$IMAGE_BACKUP_INITIAL_IMAGE_SIZE","$IMAGE_BACKUP_ADDITIONAL_IMAGE_SPACE_FOR_INCREMENTAL_BACKUPS" | do_log
            # Capture the exit status into a variable immediately
            IMAGE_BACKUP_RESULT=$?
            # 3. Capture End Stats - Stop the Stopwatch
            END_TIME=$SECONDS
            ELAPSED=$((END_TIME - START_TIME))

            # 4. Calculate Average Speed
            # We get the actual file size in bytes and divide by seconds
            FILE_BYTES=$(stat -c%s "$FULL_PATH")
            if [ "$ELAPSED" -gt 0 ]; then
                # Math: (Bytes / 1024 / 1024) / Seconds = MB/s
                AVG_SPEED=$(((FILE_BYTES / 1048576) / ELAPSED))
            else
                AVG_SPEED=0
            fi

            # 2. Format into Minutes and Seconds (01h:02m:03s)
            # %02d ensures you get '05s' instead of '5s'
            # If hours are 0, it still shows 00h
            DURATION=$(printf '%02dh:%02dm:%02ds' $((ELAPSED / 3600)) $((ELAPSED % 3600 / 60)) $((ELAPSED % 60)))
            echo "---- END OF IMAGE-BACKUP RUN -----" | do_log
            echo "Transfer Performance: ${AVG_SPEED} MB/s average over ${DURATION}" | do_log
        fi
    else # BACKUP USB DRIVE - ASSUME: SOURCE_DEV="/dev/sda"

        echo "Backing up USB to $FILENAME..." | do_log

        # Detect if we are running in a terminal (manual) or background (cron)
        if [ -t 1 ]; then

            # 2. Check if the noisy flag is in the array
            IMAGE_BACKUP_LOG_PROGRESS=1
            for opt in "${IMAGE_BACKUP_OPTIONS_ARRAY[@]}"; do
                case "$opt" in
                *progress*)
                    IMAGE_BACKUP_LOG_PROGRESS=0 # Found noisey flag - do not send the noise to the log
                    ;;
                *)
                    # Ignore everything else
                    ;;
                esac
            done

            echo "Starting image-backup image creation..." | do_log
            echo "" | do_log
            echo "Starting image-backup with command : $IMAGE_BACKUP_BIN $IMAGE_BACKUP_OPTIONS -i $FULL_PATH,$IMAGE_BACKUP_INITIAL_IMAGE_SIZE,$IMAGE_BACKUP_ADDITIONAL_IMAGE_SPACE_FOR_INCREMENTAL_BACKUPS $IMAGE_BACKUP_POST_IMAGE_NAME_OPTIONS" | do_log
            echo "" | do_log
            # Control what is logged so the progress stats do not fill the log
            if [[ "$IMAGE_BACKUP_LOG_PROGRESS" == "1" ]]; then
                # 1. Start the stopwatch
                START_TIME=$SECONDS
                "$IMAGE_BACKUP_BIN" "${IMAGE_BACKUP_OPTIONS_ARRAY[@]}" -i "$FULL_PATH","$IMAGE_BACKUP_INITIAL_IMAGE_SIZE","$IMAGE_BACKUP_ADDITIONAL_IMAGE_SPACE_FOR_INCREMENTAL_BACKUPS" | do_log
                IMAGE_BACKUP_RESULT=$?
            else # Logging and progress requested - skip logging output or the log file is huge
                if [[ "$LOG_TO_FILE" == "1" ]]; then
                    echo "Starting full backup (for incremental backups, run: $IMAGE_BACKUP_BIN $FULL_PATH)" >>"$FULL_LOG_PATH"
                fi
                # 1. Start the stopwatch
                START_TIME=$SECONDS
                "$IMAGE_BACKUP_BIN" "${IMAGE_BACKUP_OPTIONS_ARRAY[@]}" -i "$FULL_PATH","$IMAGE_BACKUP_INITIAL_IMAGE_SIZE","$IMAGE_BACKUP_ADDITIONAL_IMAGE_SPACE_FOR_INCREMENTAL_BACKUPS"
                IMAGE_BACKUP_RESULT=$?
            fi

            # 3. Capture End Stats - Stop the stopwatch
            END_TIME=$SECONDS
            ELAPSED=$((END_TIME - START_TIME))

            # 4. Calculate Average Speed
            # We get the actual file size in bytes and divide by seconds
            FILE_BYTES=$(stat -c%s "$FULL_PATH")
            if [ "$ELAPSED" -gt 0 ]; then
                # Math: (Bytes / 1024 / 1024) / Seconds = MB/s
                AVG_SPEED=$(((FILE_BYTES / 1048576) / ELAPSED))
            else
                AVG_SPEED=0
            fi

            # 5. Format into Hours, Minutes and Seconds (01h:02m:03s)
            # %02d ensures you get '05s' instead of '5s'
            # If hours are 0, it still shows 00h
            DURATION=$(printf '%02dh:%02dm:%02ds' $((ELAPSED / 3600)) $((ELAPSED % 3600 / 60)) $((ELAPSED % 60)))
            echo | do_log

            echo "Transfer Performance: ${AVG_SPEED} MB/s average over ${DURATION}" | do_log

        else # CRON:
            # CRON USB backup
            # This creates a NEW array excluding the progress flag
            IMAGE_BACKUP_CLEAN_OPTIONS_ARRAY=()
            i=0

            while [[ $i -lt ${#IMAGE_BACKUP_OPTIONS_ARRAY[@]} ]]; do
                opt="${IMAGE_BACKUP_OPTIONS_ARRAY[$i]}"

                case "$opt" in
                -o | --options)
                    # 1. Grab the next element (the values)
                    val="${IMAGE_BACKUP_OPTIONS_ARRAY[$((i + 1))]}"

                    # 2. Scrub the values
                    scrubbed_val=$(scrub_csv "$val")

                    # 3. Only add the flag if something is left after scrubbing
                    if [[ -n "$scrubbed_val" ]]; then
                        IMAGE_BACKUP_CLEAN_OPTIONS_ARRAY+=("$opt" "$scrubbed_val")
                    fi

                    # Move index forward by 2 (the flag and its value)
                    ((i += 2))
                    ;;

                *progress*)
                    # Skip standalone progress flags
                    ((i++))
                    ;;

                *)
                    # Keep everything else
                    IMAGE_BACKUP_CLEAN_OPTIONS_ARRAY+=("$opt")
                    ((i++))
                    ;;
                esac
            done

            echo "Starting image-backup image creation..." | do_log

            echo "Starting image-backup with command : $IMAGE_BACKUP_BIN ${IMAGE_BACKUP_CLEAN_OPTIONS_ARRAY[*]} -i $FULL_PATH" | do_log
            # 1. Start the stopwatch
            START_TIME=$SECONDS
            "$IMAGE_BACKUP_BIN" "${IMAGE_BACKUP_CLEAN_OPTIONS_ARRAY[@]}" -i "$FULL_PATH","$IMAGE_BACKUP_INITIAL_IMAGE_SIZE","$IMAGE_BACKUP_ADDITIONAL_IMAGE_SPACE_FOR_INCREMENTAL_BACKUPS" | do_log
            # Capture the exit status into a variable immediately
            IMAGE_BACKUP_RESULT=$?
            # 3. Capture End Stats - Stop the Stopwatch
            END_TIME=$SECONDS
            ELAPSED=$((END_TIME - START_TIME))

            # 4. Calculate Average Speed
            # We get the actual file size in bytes and divide by seconds
            FILE_BYTES=$(stat -c%s "$FULL_PATH")
            if [ "$ELAPSED" -gt 0 ]; then
                # Math: (Bytes / 1024 / 1024) / Seconds = MB/s
                AVG_SPEED=$(((FILE_BYTES / 1048576) / ELAPSED))
            else
                AVG_SPEED=0
            fi

            # 2. Format into Minutes and Seconds (01h:02m:03s)
            # %02d ensures you get '05s' instead of '5s'
            # If hours are 0, it still shows 00h
            DURATION=$(printf '%02dh:%02dm:%02ds' $((ELAPSED / 3600)) $((ELAPSED % 3600 / 60)) $((ELAPSED % 60)))
            echo "---- END OF IMAGE-BACKUP RUN -----" | do_log
            echo "Transfer Performance: ${AVG_SPEED} MB/s average over ${DURATION}" | do_log
        fi
    fi

    # TEST IF BACKUP SUCCESSFUL
    if [ "${IMAGE_BACKUP_RESULT:-0}" -ne 0 ]; then # Not equal to 0 -> Error during image-backup
        echo "" | do_log
        echo "ERROR: Backup failed during imaging! Cleaning up partial file and re-starting services..." | do_log
        echo "" | do_log

        # Re-start services and Docker containers
        startServices
        echo "" | do_log

        echo "CRITICAL: Imaging failed! (image-backup Return Code: $IMAGE_BACKUP_RESULT)" | do_log
        # If a backup file was created then delete it
        [ -f "$FULL_PATH" ] && rm "$FULL_PATH"
        # Check if sending messages - delay if waiting for internet
        if [[ "$SEND_TELEGRAM_MESSAGES" == "1" || "$SEND_GOTIFY_MESSAGES" == "1" || "$SEND_NTFY_MESSAGES" == "1" ]]; then
            echo "Pausing for 6 mins. for internet to start..." | do_log
            sleep 360
        fi

        if [ "$DRIVES_ARE_UNMOUNTED" = true ]; then
            echo "" | do_log
            remount_custom_mounts
        fi

        send_messages "❌ Backup FAILED for $HOSTNAME during imaging. Check Backup_pi.log"
        send_log_messages
        exit 1
    else
        if [ "${IMAGE_BACKUP_RESULT}" -eq 0 ]; then # Successful image-backup
            echo | do_log
            echo "Image creation using image-backup finished. Results from image-info:" | do_log
            # use image-info to display .img file info
            "$IMAGE_INFO_BIN" "$FULL_PATH" | do_log
        fi

        echo "" | do_log
        if [[ "$STOP_CONTAINERS" == "1" || "$STOP_SERVICES" == "1" ]]; then
            echo "Image creation finished. Restarting services." | do_log
        else
            echo "Image creation finished." | do_log
        fi
        

        # Re-start services and Docker containers
        startServices

        echo "Flushing write cache and verifying image integrity..." | do_log
        echo "" | do_log

        # 1. Force all data to be written to the USB hardware
        sync
        sleep 2
        IMAGE="$FULL_PATH"
        # 1. Split the path into directory and filename
        BACKUP_DIR=$(dirname "$IMAGE")
        FILE_NAME=$(basename "$IMAGE")
        # shellcheck disable=SC2034
        HASH_FILE_NAME="${FILE_NAME}.sha256"
        # 2. Save current location and move to the USB directory
        if pushd "$BACKUP_DIR" >/dev/null; then
            # TEST: Try to create a tiny dummy file
            if ! touch ".write_test" 2>/dev/null; then
                echo "ERROR: USB drive is READ-ONLY or permissions denied. Cannot create hash file." | do_log
                popd >/dev/null || echo "Warning: Could not return to previous directory" | do_log
                exit 1
            fi
            rm ".write_test"
            # If a verify is selected
            if [[ "$VERIFY_IMAGE" == "1" ]]; then # VERIFY_IMAGE=1
                echo "Generating checksum for verification..." | do_log
                echo "Read-back verification starting..." | do_log
                # Read file to confirm success by creating a sha256 hash of the file
                ACTUAL_HASH=$(pv "$FULL_PATH" | sha256sum | awk '{print $1}')
                # If hash was generated - then .img file was verified
                if [[ -n "$ACTUAL_HASH" ]]; then
                    echo "SUCCESS: Verification passed. (Hash: $ACTUAL_HASH)" | do_log
                    echo "IMAGE CREATION SUCCESS: Verification passed!" | do_log
                    echo "" | do_log

                    # Send messages if set to do so
                    if [[ "$SEND_MESSAGES_ONLY_ON_ERROR" != "1" && "$SEND_CONFIRMATON_MESSAGE_ONLY" != "1" ]]; then
                        send_messages "✅ Image creation verified successful: $FILENAME"
                    fi
                else # NO hash was generated
                    echo "ERROR: Read-back verification failed! Your backup might be corrupt. Cleaning up partial file..." | do_log
                    echo "" | do_log

                    [ -f "$FULL_PATH" ] && rm "$FULL_PATH"

                    if [ "$DRIVES_ARE_UNMOUNTED" = true ]; then
                        echo "" | do_log
                        remount_custom_mounts
                    fi

                    send_messages "❌ Backup FAILED for $HOSTNAME. Hash mismatch! Your backup might be corrupt. Check Backup_pi.log"
                    send_log_messages
                    exit 1
                fi
            else # No verify selected - Assume good .img file
                if [[ "$SEND_MESSAGES_ONLY_ON_ERROR" != "1" && "$SEND_CONFIRMATON_MESSAGE_ONLY" != "1" ]]; then
                    send_messages "✅ Image creation successful: $FILENAME"
                fi
            fi
            # 5. Return to exactly where we started
            popd >/dev/null 2>&1 || echo "Warning: Could not return to previous directory" | do_log
        else
            echo "ERROR: Could not access directory $BACKUP_DIR" | do_log
        fi
    fi

    # Perform PiShrink if selected and NOT a forced initial
    if [[ "$PISHRINK_IMAGE" == "1" && "$FORCED_INITIAL" != "TRUE" && -n "$PISHRINK_BIN" ]]; then
        echo "" | do_log
        echo "Starting PiShrink" | do_log
        echo "" | do_log

        # Set arguments for pishrink according to setting selected
        # 1. Initialize as an array with the first argument
        PISHRINK_ARGS=("-s")

        # 2. Append the -z option if needed using +=
        [[ "$PISHRINK_AND_GZIP_IMAGE" == "1" ]] && PISHRINK_ARGS+=("-z")

        # Perform PiShrink
        "$PISHRINK_BIN" "${PISHRINK_ARGS[@]}" "$FULL_PATH" | do_log
        # show image-info after PiShrink if it was not gzipped
        if [[ "$PISHRINK_AND_GZIP_IMAGE" != "1" ]]; then
            "$IMAGE_INFO_BIN" "$FULL_PATH" | do_log
        else
            FULL_PATH="$FULL_PATH.gz"
        fi
    fi
    echo "" | do_log

    # Purge old backups if number of backups to keep is greater than 0
    if ((BACKUP_ANTAL > 0)); then
        # Delete if there are more than ${BACKUP_ANTAL}
        echo "Keeping only the latest $BACKUP_ANTAL backups..." | do_log

        # For System Images (if you want)
        rotate_backups_and_logs "${BACKUP_PATH}/${HOSTNAME}-${OS_NAME}-${ARCHITECTURE}" "$BACKUP_ANTAL" "System Images"

        echo "" | do_log
    else
        echo "Warning: BACKUP_ANTAL is 0. Skipping purge to prevent the removal of all backups." | do_log
    fi
    # Purge Logs if selected
    # Purge old logs if number of logs to keep is greater than 0
    if ((LOG_ANTAL > 0)); then
        LOG_PATTERN="Backup_pi-${HOSTNAME}-${OS_NAME}-${ARCHITECTURE}"
        # Ensure the directory exists before we try to enter it
        if [[ -d $LOG_TO_FILE_DIRECTORY ]]; then
            pushd "${LOG_TO_FILE_DIRECTORY}" >/dev/null || echo "Warning: Could not save current directory" | do_log
            # For Log Files
            rotate_backups_and_logs "$LOG_PATTERN" "$LOG_ANTAL" "Log Files"

            # Change back to starting directory
            popd >/dev/null || echo "Warning: Could not return to previous directory" | do_log
        fi
    else
        echo "Warning: LOG_ANTAL is 0. Skipping purge to prevent the removal of all logs." | do_log
    fi
    echo "Rotation complete." | do_log
    echo "" | do_log

    # Pause if not verifying image and not using Pishrink and sending messages to get Internet back up after re-starting
    if [[ "$VERIFY_IMAGE" == "0" && "$PISHRINK_IMAGE" == "0" && ("$SEND_TELEGRAM_MESSAGES" == "1" || "$SEND_GOTIFY_MESSAGES" == "1" || "$SEND_NTFY_MESSAGES" == "1") ]]; then
        echo "Pausing to allow messaging to work if Internet was re-started..." | do_log
        echo "" | do_log
        sleep 240
    fi

    if [ "$DRIVES_ARE_UNMOUNTED" = true ]; then
        echo "" | do_log
        remount_custom_mounts
    fi

    # 1. Get exact bytes (Works for both .img and .img.gz)
    FINAL_BYTES=$(stat -c%s "$FULL_PATH")

    # Multiply by 100 first to get "hundredths of a GB"
    TOTAL_HUNDREDTHS=$(( (FINAL_BYTES * 100) / 1073741824 ))

    WHOLE=$(( TOTAL_HUNDREDTHS / 100 ))
    FRACTION=$(( TOTAL_HUNDREDTHS % 100 ))

    # Format with printf to ensure .05 doesn't become .5
    FINAL_SIZE=$(printf "%d.%02d GB" "$WHOLE" "$FRACTION")
    # Send messages if so configured
    if [[ "$SEND_MESSAGES_ONLY_ON_ERROR" == "0" || "$SEND_CONFIRMATON_MESSAGE_ONLY" == "1" ]]; then
        if [[ "$PISHRINK_AND_GZIP_IMAGE" == "1" && -n "$PISHRINK_BIN" && "$FORCED_INITIAL" != "TRUE" ]]; then #  PISHRINK_AND_GZIP_IMAGE
            MESSAGE="✅ Backup Successful for $HOSTNAME to: $FILENAME.gz"
            FINAL_REPORT="🏁 *Backup Mission Debrief* 🏁
                    ---------------------------------
                    🖥️ Host: $HOSTNAME
                    📦 Mode: $BACKUP_MODE COMPRESSED
                    📋 File: $FILENAME.gz
                    📊 Size: $FINAL_SIZE
                    🛡️ Integrity: VERIFIED
                    ---------------------------------"
                    # ⏱️ Time: $DURATION
                    # ♻️ Purge Status: $PURGE_RESULT"
        else
            MESSAGE="✅ Backup Successful for $HOSTNAME to: $FILENAME"
            FINAL_REPORT="🏁 *Backup Mission Debrief* 🏁
                    ---------------------------------
                    🖥️ Host: $HOSTNAME
                    📦 Mode: $BACKUP_MODE
                    📋 File: $FILENAME
                    📊 Size: $FINAL_SIZE
                    🛡️ Integrity: VERIFIED
                    ---------------------------------"
                    # ⏱️ Time: $DURATION
                    # ♻️ Purge Status: $PURGE_RESULT"
        fi

        send_messages "$MESSAGE"
        send_messages "$FINAL_REPORT"
    fi
    if [[ "$LOG_TO_FILE" == "1" ]]; then
        echo "Backup script execution completed successfully" >>"$FULL_LOG_PATH"
        echo "" >>"$FULL_LOG_PATH"
    fi
    if [[ "$SEND_CONFIRMATON_MESSAGE_ONLY" == "0" && "$SEND_LOG_MESSAGES" == "1" ]]; then
        echo "Sending log file messages..." >>"$FULL_LOG_PATH"
        echo "" >>"$FULL_LOG_PATH"
        send_log_messages
    fi
elif [[ "$BACKUP_MODE" == "IMAGE INCREMENTAL" ]]; then
    echo "Performing Incremental backup..." | do_log
    echo "" | do_log
    echo "Checking for available space in backup image file: $FILENAME" | do_log # INCREMENTAL IMAGE Backup on $HOSTNAME to: $FILENAME at $(date)
    echo "" | do_log

    # create an empty folder to get all possibe files transferred and size
    mkdir -p /tmp/empty >>/dev/null
    echo "Calculating rsync space needed..." | do_log
    # Calculate full backup size using
    # rsync command from image-backup:
    # rsync -aDH --dry-run --itemize-changes --partial --numeric-ids --delete --force --exclude "${MNTPATH}" --exclude '/dev' \
    # --exclude '/lost+found' --exclude '/media' --exclude '/mnt' --exclude '/proc' --exclude '/run' --exclude '/sys' --exclude '/tmp' --exclude '/var/swap' \
    # --exclude '/etc/udev/rules.d/70-persistent-net.rules' --exclude '/var/lib/asterisk/astdb.sqlite3-journal' "${OPTIONS[@]}" / "${MNTPATH}/")"
    RSYNC_TOTAL_1K_BLOCKS_NEEDED=$("$RSYNC_BIN" -aDHn --stats --exclude "/tmp/empty/" --exclude '/dev' --exclude '/lost+found' --exclude '/media' \
        --exclude '/mnt' --exclude '/proc' --exclude '/run' --exclude '/sys' --exclude '/tmp' --exclude '/var/swap' \
        --exclude '/etc/udev/rules.d/70-persistent-net.rules' --exclude '/var/lib/asterisk/astdb.sqlite3-journal' \
        / /tmp/empty/ | awk '/Total file size/ { gsub(/,/, "", $4); print int($4 / 1024) }')
    # use image-info on backup image to get space and size information
    # shellcheck disable=SC2034
    read -r root_1k root_used root_avail root_pct_use <<< "$("$IMAGE_INFO_BIN" "$FULL_PATH" | awk '$1=="root" {print $3, $4, $5, $6}')"
    echo "Image file Root total 1k Blocks available (all space): $root_1k" | do_log
    echo "Total 1K blocks needed for image-backup: $RSYNC_TOTAL_1K_BLOCKS_NEEDED" | do_log
    # Calculate BLOCKS_NEEDED plus 5%
    BLOCKS_NEEDED_PLUS_5_PERCENT=$((RSYNC_TOTAL_1K_BLOCKS_NEEDED + (RSYNC_TOTAL_1K_BLOCKS_NEEDED / 20)))

    # echo "Image file Root used: $root_used" | do_log
    # echo "Image file Root available: $root_avail" | do_log
    # echo "Image file Root percent used: $root_pct_use" | do_log
    BLOCKS_AVAIL_MINUS_NEEDED=$((root_1k - BLOCKS_NEEDED_PLUS_5_PERCENT))
    echo "1K Blocks total available - Total 1K blocks needed (Plus 5 percent) = $BLOCKS_AVAIL_MINUS_NEEDED" | do_log
    echo "" | do_log
    if ((root_1k < (RSYNC_TOTAL_1K_BLOCKS_NEEDED * 105 / 100))); then
        # BELOW FOR TESTING
        # if (( 1 < (RSYNC_TOTAL_1K_BLOCKS_NEEDED * 105 / 100) )); then
        echo "ERROR: Not enough space in $FILENAME!" | do_log
        echo "Backup file ($FILENAME) is $((root_1k / 1024 / 1024)) GB" | do_log
        echo "Required (with margin): $((RSYNC_TOTAL_1K_BLOCKS_NEEDED * 105 / 100 / 1024 / 1024)) GB" | do_log
        echo "To continue doing incremental backups a new image file needs to be generated or space added to the current backup." | do_log

        echo "" | do_log

        send_messages "❌ Incremental backup FAILED for $HOSTNAME. INSUFFICIENT SPACE LEFT IN MOST RECENT IMAGE FILE. Check Backup_pi.log"
        send_log_messages
        exit 1

    else

        echo "Space check passed. Starting backup..." | do_log

    fi

    echo "" | do_log

    # Stop services and Docker containers before backup
    stopServices
    if [[ "$STOP_CONTAINERS" == "1" || "$STOP_SERVICES" == "1" ]]; then
        echo "Services stopped..." | do_log
        echo "" | do_log
    fi

    echo "Starting incremental update to image file using image-backup command:  $IMAGE_BACKUP_BIN $IMAGE_BACKUP_OPTIONS $FULL_PATH" | do_log # /usr/local/bin/image-backup $IMAGE_BACKUP_OPTIONS -i $FULL_PATH,$IMAGE_BACKUP_INITIAL_IMAGE_SIZE,$IMAGE_BACKUP_ADDITIONAL_IMAGE_SPACE_FOR_INCREMENTAL_BACKUPS $IMAGE_BACKUP_POST_IMAGE_NAME_OPTIONS" | do_log
    echo "" | do_log
    echo "image-backup: Incremental backup - adding changed files to: $FULL_PATH"
    # Get Starting file size
    START_FILE_BYTES=$(stat -c%s "$FULL_PATH")
    # Detect if we are running in a terminal (manual) or background (cron)
    if [ -t 1 ]; then
        IMAGE_BACKUP_LOG_PROGRESS=1
        for opt in "${IMAGE_BACKUP_OPTIONS_ARRAY[@]}"; do
            case "$opt" in
            *progress*)
                IMAGE_BACKUP_LOG_PROGRESS=0 # Set to not log image-backup command since progress would fill the log
                ;;
            *)
                # Ignore everything else
                ;;
            esac

        done
        if [[ "$IMAGE_BACKUP_LOG_PROGRESS" == "1" ]]; then
            # Start stopwatch
            START_TIME=$SECONDS
            # Perform incremental backup
            "$IMAGE_BACKUP_BIN" "${IMAGE_BACKUP_OPTIONS_ARRAY[@]}" "$FULL_PATH" | do_log
            IMAGE_BACKUP_RESULT=$?
        else # Logging and progress requested - skip logging output or the log file is huge
            if [[ "$LOG_TO_FILE" == "1" ]]; then
                echo "Starting incremental backup to: $FULL_PATH" >>"$FULL_LOG_PATH"
            fi
            # Start stopwatch
            START_TIME=$SECONDS
            # Perform backup - not to log file
            "$IMAGE_BACKUP_BIN" "${IMAGE_BACKUP_OPTIONS_ARRAY[@]}" "$FULL_PATH"
            IMAGE_BACKUP_RESULT=$?
        fi

    else # CRON job
        # Clean options of any *progress options
        IMAGE_BACKUP_CLEAN_OPTIONS_ARRAY=()
        i=0

        while [[ $i -lt ${#IMAGE_BACKUP_OPTIONS_ARRAY[@]} ]]; do
            opt="${IMAGE_BACKUP_OPTIONS_ARRAY[$i]}"

            case "$opt" in
            -o | --options)
                # 1. Grab the next element (the values)
                val="${IMAGE_BACKUP_OPTIONS_ARRAY[$((i + 1))]}"

                # 2. Scrub the values
                scrubbed_val=$(scrub_csv "$val")

                # 3. Only add the flag if something is left after scrubbing
                if [[ -n "$scrubbed_val" ]]; then
                    IMAGE_BACKUP_CLEAN_OPTIONS_ARRAY+=("$opt" "$scrubbed_val")
                fi

                # Move index forward by 2 (the flag and its value)
                ((i += 2))
                ;;

            *progress*)
                # Skip standalone progress flags
                ((i++))
                ;;

            *)
                # Keep everything else
                IMAGE_BACKUP_CLEAN_OPTIONS_ARRAY+=("$opt")
                ((i++))
                ;;
            esac
        done
        # Start the stopwatch
        START_TIME=$SECONDS
        # Perform the incremental backup
        "$IMAGE_BACKUP_BIN" "${IMAGE_BACKUP_CLEAN_OPTIONS_ARRAY[@]}" "$FULL_PATH" | do_log
        IMAGE_BACKUP_RESULT=$?
    fi

    # 3. Capture End Stats
    END_TIME=$SECONDS
    ELAPSED=$((END_TIME - START_TIME))

    # 4. Calculate Average Speed
    # We get the Final actual file size in bytes, subtract the starting file size in bytes and divide by seconds
    FINAL_FILE_BYTES=$(stat -c%s "$FULL_PATH")
    FILE_BYTES=$((FINAL_FILE_BYTES - START_FILE_BYTES))
    if [ "$ELAPSED" -gt 0 ]; then
        
        # 1. Convert Bytes to "Deci-MegaBytes" by multiplying by 100 first
        # (Bytes * 100) / 1048576 = Total 1/100th Megabytes
        # For 592,075,730 bytes: (59,207,573,000 / 1,048,576) = 56,464
        TOTAL_HUNDREDTHS=$(( (FILE_BYTES * 100 / 1048576) / ELAPSED ))

        # 2. Extract the Whole number and the Decimal part
        WHOLE=$(( TOTAL_HUNDREDTHS / 100 ))
        FRACTION=$(( TOTAL_HUNDREDTHS % 100 ))

        # 3. Format with a leading zero if the fraction is less than 10 (e.g., .05)
        AVG_SPEED=$(printf "%d.%02d" "$WHOLE" "$FRACTION")
    else
        AVG_SPEED=0
    fi
    DURATION=$(printf '%02dh:%02dm:%02ds' $((ELAPSED / 3600)) $((ELAPSED % 3600 / 60)) $((ELAPSED % 60)))
    echo "" | do_log
    echo "---- END OF IMAGE-BACKUP RUN -----" | do_log
    echo "" | do_log
    # 3. Use it in your log # NO PERFORMANCE ON INCREMENTAL - CAN NOT ESTIMATE TRANSFER BYTES EASILY
    # echo "Transfer Performance: ${AVG_SPEED} MB/s average over ${DURATION}" | do_log
    echo "Transfer completed in ${DURATION}" | do_log
    if [ "${IMAGE_BACKUP_RESULT:-0}" -ne 0 ]; then
        echo "" | do_log
        echo "ERROR: Backup failed during imaging! Cleaning up partial file and re-starting services..." | do_log
        echo "" | do_log

        startServices
        echo "" | do_log
        echo "CRITICAL: Imaging failed! (image-backup Return Code: $IMAGE_BACKUP_RESULT)" | do_log
        # Remove bad file if it exists
        [ -f "$FULL_PATH" ] && rm "$FULL_PATH"
        if [[ "$SEND_TELEGRAM_MESSAGES" == "1" || "$SEND_GOTIFY_MESSAGES" == "1" || "$SEND_NTFY_MESSAGES" == "1" ]]; then
            echo "Pausing for 6 mins. for internet to start..." | do_log
            sleep 360
        fi

        if [ "$DRIVES_ARE_UNMOUNTED" = true ]; then
            echo "" | do_log
            remount_custom_mounts
        fi

        send_messages "❌ Backup FAILED for $HOSTNAME during imaging. Check Backup_pi.log"
        send_log_messages
        exit 1
    else
        if [ "${IMAGE_BACKUP_RESULT}" -eq 0 ]; then
            echo "" | do_log
            echo "Image creation using image-backup finished. Results from image-info:" | do_log
            # Display new image-info results
            "$IMAGE_INFO_BIN" "$FULL_PATH" | do_log
        fi

        echo "" | do_log
        if [[ "$STOP_CONTAINERS" == "1" || "$STOP_SERVICES" == "1" ]]; then
            echo "Image creation finished. Restarting services." | do_log
        else
            echo "Image creation finished." | do_log
        fi
        
        # Restart services and Docker containers
        startServices

        echo "Flushing write cache and verifying image integrity..." | do_log
        echo "" | do_log

        # 1. Force all data to be written to the USB hardware
        sync
        sleep 2
        IMAGE="$FULL_PATH"
        # 1. Split the path into directory and filename
        BACKUP_DIR=$(dirname "$IMAGE")
        FILE_NAME=$(basename "$IMAGE")
        # HASH_FILE_NAME="${FILE_NAME}.sha256"

        # 2. Save current location and move to the USB directory

        if pushd "$BACKUP_DIR" >/dev/null; then
            # TEST: Try to create a tiny dummy file
            if ! touch ".write_test" 2>/dev/null; then
                echo "ERROR: USB drive is READ-ONLY or permissions denied. Cannot create hash file." | do_log
                popd >/dev/null || echo "Warning: Could not return to previous directory" | do_log
                exit 1
            fi
            rm ".write_test"

            if [[ "$VERIFY_IMAGE" == "1" ]]; then # VERIFY_IMAGE=1
                echo "Generating checksum for verification..." | do_log
                echo "Read-back verification starting..." | do_log
                # Read file using sha256 to test if file can be read
                ACTUAL_HASH=$(pv "$FULL_PATH" | sha256sum | awk '{print $1}')
                echo "" | do_log
                # If hash exists then verification was successful
                if [[ -n "$ACTUAL_HASH" ]]; then
                    echo "SUCCESS: Verification passed. (Hash: $ACTUAL_HASH)" | do_log
                    echo "IMAGE CREATION SUCCESS: Verification passed!" | do_log
                    echo "" | do_log

                    # Send messages if so set
                    if [[ "$SEND_MESSAGES_ONLY_ON_ERROR" != "1" && "$SEND_CONFIRMATON_MESSAGE_ONLY" != "1" ]]; then
                        send_messages "✅ Image creation verified successful: $FILENAME"
                    fi
                else # File could not be read
                    echo "ERROR: Read-back verification failed! Your backup might be corrupt. Cleaning up partial file..." | do_log
                    echo "" | do_log

                    [ -f "$FULL_PATH" ] && rm "$FULL_PATH"

                    if [ "$DRIVES_ARE_UNMOUNTED" = true ]; then
                        echo "" | do_log
                        remount_custom_mounts
                    fi

                    send_messages "❌ Backup FAILED for $HOSTNAME. Read-back verification failed! Your backup might be corrupt. Check Backup_pi.log"
                    send_log_messages
                    exit 1
                fi
            else
                if [[ "$SEND_MESSAGES_ONLY_ON_ERROR" != "1" && "$SEND_CONFIRMATON_MESSAGE_ONLY" != "1" ]]; then
                    send_messages "✅ Image creation successful: $FILENAME"
                fi
            fi
            # 5. Return to exactly where we started
            popd >/dev/null 2>&1 || echo "Warning: Could not return to previous directory" | do_log
        else
            echo "ERROR: Could not access directory $BACKUP_DIR" | do_log
        fi
    fi
    # NO PISHRINK ON AN INCREMENTAL

    # NO FILE OR LOG ROTATION ON AN INCREMENTAL

    if [ "$DRIVES_ARE_UNMOUNTED" = true ]; then
        echo "" | do_log
        remount_custom_mounts
    fi

    # Send messages if so configured  CUT || "$SEND_CONFIRMATON_MESSAGE_ONLY" == "1" 
    if [[ "$SEND_MESSAGES_ONLY_ON_ERROR" == "0" ]]; then
        # FINAL_SIZE=$(du -sh "$FULL_PATH" | awk '{print $1}')
        FINAL_BYTES=$(stat -c%s "$FULL_PATH")

        # Multiply by 100 first to get "hundredths of a GB"
        TOTAL_HUNDREDTHS=$(( (FINAL_BYTES * 100) / 1073741824 ))

        WHOLE=$(( TOTAL_HUNDREDTHS / 100 ))
        FRACTION=$(( TOTAL_HUNDREDTHS % 100 ))

        # Format with printf to ensure .05 doesn't become .5
        FINAL_SIZE=$(printf "%d.%02d GB" "$WHOLE" "$FRACTION")
        MESSAGE="✅ Backup Successful for $HOSTNAME to: $FILENAME"
        FINAL_REPORT="🏁 *Backup Mission Debrief* 🏁
                    ---------------------------------
                    🖥️ Host: $HOSTNAME
                    📦 Mode: $BACKUP_MODE
                    📋 File: $FILENAME
                    📊 Size: $FINAL_SIZE
                    🛡️ Integrity: VERIFIED
                    ---------------------------------"
                    # ⏱️ Time: $DURATION
                    # ♻️ Purge Status: $PURGE_RESULT"
        send_messages "$MESSAGE"
        send_messages "$FINAL_REPORT"
    fi
    if [[ "$LOG_TO_FILE" == "1" ]]; then
        echo "Backup script execution completed successfully" >>"$FULL_LOG_PATH"
        echo "" >>"$FULL_LOG_PATH"
    fi
    if [[ "$SEND_CONFIRMATON_MESSAGE_ONLY" == "0" && "$SEND_LOG_MESSAGES" == "1" ]]; then
        echo "Sending log file messages..." | do_log
        echo "" | do_log
        send_log_messages
    fi
fi
echo ""
echo "Backup script execution completed successfully"
echo ""
