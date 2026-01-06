#!/bin/bash
set -e

# --- Logging Functions ---
log_info() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $1"
}

log_warning() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [WARNING] $1" >&2
}

log_error() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] $1" >&2
    exit 1
}

# --- Check for Root Privileges ---
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run with root privileges. Please use 'sudo'."
fi

# --- Variable Definitions ---
DEVICE="/dev/sdb"
PARTITION="${DEVICE}1"
MOUNT_POINT="/var"
BACKUP_DIR="/var_old"
TEMP_MOUNT="/mnt/tempvar"

log_info "Starting migration of ${MOUNT_POINT} to new disk ${DEVICE}"
log_info "WARNING: All data on ${DEVICE} will be erased without confirmation."

# --- 0. Check Disk Usage ---
log_info "Checking current disk usage..."
echo "=== Current Disk Status ==="
df -h | grep -E "^/dev|Filesystem"
echo ""
echo "=== /var usage ==="
df -h /var
echo ""
echo "=== Top 5 largest directories in /var ==="
sudo du -h /var/* 2>/dev/null | sort -rh | head -5 || true

# --- 1. Stop Docker and Related Services ---
log_info "Stopping services that use ${MOUNT_POINT}..."

stop_all_services() {
    # Stop Docker containers
    if command -v docker >/dev/null 2>&1; then
        log_info "Stopping Docker containers..."
        docker stop $(docker ps -q) 2>/dev/null || true
        sleep 5
    fi
    
    # Stop Docker service
    if systemctl is-active --quiet docker; then
        log_info "Stopping Docker service..."
        systemctl stop docker || log_warning "Failed to stop Docker"
    fi
    
    # Stop other services that use /var
    local services=("mysql" "mariadb" "postgresql" "redis" "mongod" "nginx" "apache2")
    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log_info "Stopping $svc..."
            systemctl stop "$svc" || log_warning "Failed to stop $svc"
        fi
    done
}

stop_all_services

# --- 2. Unmount Device if Mounted ---
log_info "Unmounting ${DEVICE} if mounted..."
for mount in $(mount | grep "$DEVICE" | awk '{print $1}'); do
    sudo umount "$mount" 2>/dev/null || true
done

# --- 3. Create Partition and Filesystem ---
log_info "Creating partition on ${DEVICE}..."
# Clear existing partition table
sudo dd if=/dev/zero of="$DEVICE" bs=1M count=10 2>/dev/null || true

# Create GPT partition table and single partition
sudo parted -s "$DEVICE" mklabel gpt
sudo parted -s "$DEVICE" mkpart primary ext4 0% 100%
sleep 2

log_info "Formatting ${PARTITION} as ext4..."
# Optimize for Docker: more inodes, no reserved space
sudo mkfs.ext4 -F -i 8192 -m 0 "$PARTITION"
log_info "Partition created and formatted successfully."

# --- 4. Mount New Partition and Copy Data Directly ---
log_info "Mounting new partition to ${TEMP_MOUNT}..."
sudo mkdir -p "$TEMP_MOUNT"
sudo mount "$PARTITION" "$TEMP_MOUNT"

log_info "Starting direct copy from ${MOUNT_POINT} to new partition..."
log_info "This is both the backup AND the migration in one step!"

# Calculate time estimate
START_TIME=$(date +%s)

# Use rsync if available (faster, resumeable)
if command -v rsync >/dev/null 2>&1; then
    log_info "Using rsync for efficient data transfer..."
    sudo rsync -avxHAX --progress --stats \
          --exclude=/var/run \
          --exclude=/var/lock \
          --exclude=/var/tmp \
          "$MOUNT_POINT/" "$TEMP_MOUNT/"
else
    log_info "Using cp for data transfer..."
    sudo cp -a "$MOUNT_POINT/." "$TEMP_MOUNT/"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log_info "Data copy completed in ${DURATION} seconds."

# --- 5. Create Necessary Directories ---
log_info "Creating required directories..."
sudo mkdir -p "$TEMP_MOUNT"/{run,lock,tmp}
sudo chmod 1777 "$TEMP_MOUNT"/tmp

# --- 6. Verify Data Integrity ---
log_info "Verifying data integrity..."
SRC_COUNT=$(sudo find "$MOUNT_POINT" -type f 2>/dev/null | wc -l)
DST_COUNT=$(sudo find "$TEMP_MOUNT" -type f 2>/dev/null | wc -l)

log_info "Source files: $SRC_COUNT"
log_info "Destination files: $DST_COUNT"

if [ "$DST_COUNT" -lt "$((SRC_COUNT * 90 / 100))" ]; then
    log_warning "Significant file count mismatch!"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Aborting. Data remains on new partition at ${TEMP_MOUNT}"
        exit 1
    fi
fi

# --- 7. Backup Old /var and Mount New ---
log_info "Backing up old ${MOUNT_POINT} to ${BACKUP_DIR}..."
sudo mv "$MOUNT_POINT" "$BACKUP_DIR" 2>/dev/null || log_error "Failed to move old ${MOUNT_POINT}"

log_info "Creating new ${MOUNT_POINT} directory..."
sudo mkdir -p "$MOUNT_POINT"

log_info "Remounting new partition to ${MOUNT_POINT}..."
sudo umount "$TEMP_MOUNT"
sudo mount "$PARTITION" "$MOUNT_POINT"

# --- 8. Update /etc/fstab ---
log_info "Updating /etc/fstab for permanent mount..."
UUID=$(sudo blkid -s UUID -o value "$PARTITION")
[ -z "$UUID" ] && log_error "Failed to get UUID"

# Backup fstab
sudo cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d)

# Remove old /var entries and add new
sudo sed -i "\|${MOUNT_POINT}[[:space:]]|d" /etc/fstab
echo "UUID=${UUID} ${MOUNT_POINT} ext4 defaults,noatime,nodiratime 0 1" | sudo tee -a /etc/fstab

# --- 9. Restart Services ---
log_info "Restarting services..."
start_all_services() {
    if command -v docker >/dev/null 2>&1; then
        log_info "Starting Docker..."
        systemctl start docker
        sleep 5
        
        # Restart containers that were previously running
        if docker ps -a --format "{{.Names}}" | grep -q .; then
            log_info "Restarting Docker containers..."
            docker start $(docker ps -aq) 2>/dev/null || true
        fi
    fi
    
    # Start other services
    local services=("mysql" "mariadb" "postgresql" "redis" "mongod" "nginx" "apache2")
    for svc in "${services[@]}"; do
        if systemctl list-unit-files | grep -q "${svc}.service"; then
            log_info "Starting $svc..."
            systemctl start "$svc" 2>/dev/null || true
        fi
    done
}

start_all_services

# --- 10. Final Verification ---
log_info "=== MIGRATION COMPLETE ==="
echo ""
echo "=== Disk Space Before/After ==="
echo "Old root usage:"
df -h / | grep "/$"
echo ""
echo "New /var usage:"
df -h /var
echo ""
echo "=== Docker Status ==="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.RunningFor}}" 2>/dev/null || echo "Docker not running"
echo ""
echo "=== Important Information ==="
echo "1. Old /var data backed up to: ${BACKUP_DIR}"
echo "2. New partition UUID: ${UUID}"
echo "3. fstab backup: /etc/fstab.backup.$(date +%Y%m%d)"
echo ""
echo "=== Next Steps ==="
echo "1. Verify all services are running:"
echo "   systemctl status docker"
echo "   docker ps"
echo ""
echo "2. Test your applications"
echo ""
echo "3. After 24-48 hours (if everything works), remove backup:"
echo "   sudo rm -rf ${BACKUP_DIR}"
echo ""
echo "4. Consider setting Docker storage limits in /etc/docker/daemon.json:"
echo '   {"storage-driver": "overlay2", "storage-opts": ["overlay2.size=50G"]}'

exit 0
