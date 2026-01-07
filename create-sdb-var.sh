#!/bin/bash
set -e

# --- Color Definitions for Better Readability ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Logging Functions ---
log_info() {
    echo -e "${GREEN}$(date +'%Y-%m-%d %H:%M:%S') [INFO]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}$(date +'%Y-%m-%d %H:%M:%S') [WARNING]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}$(date +'%Y-%m-%d %H:%M:%S') [ERROR]${NC} $1" >&2
    exit 1
}

log_step() {
    echo -e "${BLUE}$(date +'%Y-%m-%d %H:%M:%S') [STEP]${NC} $1"
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
DOCKER_DIR="/var/lib/docker"
LOCK_CHECK_FILE="/tmp/var_migration.lock"

log_step "================================================"
log_step "   MIGRATION SCRIPT: /var to ${DEVICE}"
log_step "================================================"
log_info "Starting migration of ${MOUNT_POINT} to new disk ${DEVICE}"
log_warning "WARNING: All data on ${DEVICE} will be erased without confirmation!"
log_warning "This process will stop Docker and related services temporarily."

# --- Create Lock File ---
log_info "Creating lock file to prevent duplicate execution..."
if [ -f "$LOCK_CHECK_FILE" ]; then
    log_error "Another migration process might be running or previous process was interrupted."
    log_error "If you're sure no other process is running, remove: $LOCK_CHECK_FILE"
fi
echo "PID: $$" > "$LOCK_CHECK_FILE"
echo "Start time: $(date)" >> "$LOCK_CHECK_FILE"
echo "Device: $DEVICE" >> "$LOCK_CHECK_FILE"
trap 'rm -f $LOCK_CHECK_FILE' EXIT

# --- 1. Pre-Migration Checks ---
log_step "1. PRE-MIGRATION CHECKS"
log_info "Checking current disk usage..."

echo -e "\n${BLUE}=== Current Disk Status ===${NC}"
df -h | head -1
df -h | grep -E "^/dev/sd|^/dev/vd|^/dev/xvd" || true

echo -e "\n${BLUE}=== /var Usage ===${NC}"
df -h "$MOUNT_POINT" || log_warning "Cannot get /var usage"

echo -e "\n${BLUE}=== Docker Disk Usage ===${NC}"
if [ -d "$DOCKER_DIR" ]; then
    sudo du -sh "$DOCKER_DIR" 2>/dev/null | head -5 || log_warning "Cannot read Docker directory"
else
    log_info "Docker directory not found"
fi

# Check if device exists
if [ ! -e "$DEVICE" ]; then
    log_error "Device $DEVICE does not exist. Please check device name."
fi

# Check if device is mounted
if mount | grep -q "^$DEVICE"; then
    log_warning "$DEVICE is currently mounted. Please unmount it first."
    log_info "Mounted partitions:"
    mount | grep "^$DEVICE"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# --- 2. Stop All Related Services ---
log_step "2. STOPPING SERVICES"
log_info "Stopping services that use ${MOUNT_POINT}..."

# Function to check if service exists and is active
service_exists_and_active() {
    local service=$1
    if systemctl list-unit-files | grep -q "$service.service" && \
       systemctl is-active --quiet "$service" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Stop Docker services with proper order
stop_docker_services() {
    log_info "Stopping Docker services..."
    
    # Stop docker.socket first
    if service_exists_and_active "docker.socket"; then
        log_info "Stopping docker.socket..."
        sudo systemctl stop docker.socket
        sleep 2
    fi
    
    # Stop docker service
    if service_exists_and_active "docker"; then
        log_info "Stopping docker service..."
        sudo systemctl stop docker
        sleep 5
    fi
    
    # Force kill any remaining docker processes
    DOCKER_PROCESSES=$(pgrep -f docker 2>/dev/null | wc -l)
    if [ "$DOCKER_PROCESSES" -gt 0 ]; then
        log_warning "Found $DOCKER_PROCESSES remaining Docker processes"
        log_info "Force stopping Docker processes..."
        sudo pkill -9 -f docker || true
        sleep 3
    fi
    
    # Check for processes using /var/lib/docker
    log_info "Checking for processes using $DOCKER_DIR..."
    LOCKED_PROCESSES=$(sudo lsof "$DOCKER_DIR" 2>/dev/null | wc -l)
    if [ "$LOCKED_PROCESSES" -gt 0 ]; then
        log_warning "Found $LOCKED_PROCESSES processes still using $DOCKER_DIR"
        log_info "Listing processes..."
        sudo lsof "$DOCKER_DIR" 2>/dev/null | head -10
        read -p "Force kill these processes? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo lsof -t "$DOCKER_DIR" 2>/dev/null | xargs sudo kill -9 2>/dev/null || true
            sleep 3
        fi
    fi
}

# Stop Docker
stop_docker_services

# Stop other services that might use /var
SERVICES_TO_STOP=(
    "mysql"
    "mariadb"
    "postgresql"
    "redis"
    "mongod"
    "elasticsearch"
    "nginx"
    "apache2"
    "httpd"
    "cassandra"
    "rabbitmq-server"
    "kafka"
    "zookeeper"
    "prometheus"
    "grafana-server"
)

for SERVICE in "${SERVICES_TO_STOP[@]}"; do
    if service_exists_and_active "$SERVICE"; then
        log_info "Stopping $SERVICE..."
        sudo systemctl stop "$SERVICE" || log_warning "Failed to stop $SERVICE"
    fi
done

# Extra safety: Stop any service using /var
log_info "Checking for any other services using /var..."
SERVICES_USING_VAR=$(sudo lsof +D "$MOUNT_POINT" 2>/dev/null | grep -E 'systemd|^COMMAND' | grep systemd | awk '{print $1}' | sort -u)
for SERVICE in $SERVICES_USING_VAR; do
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        log_info "Stopping $SERVICE (detected using /var)..."
        sudo systemctl stop "$SERVICE" || true
    fi
done

sleep 5

# --- 3. Unmount Any Existing Mounts ---
log_step "3. UNMOUNTING EXISTING MOUNTS"
log_info "Checking for existing mounts on $DEVICE..."

if mount | grep -q "^$DEVICE"; then
    log_info "Unmounting $DEVICE partitions..."
    for MOUNT in $(mount | grep "^$DEVICE" | awk '{print $3}'); do
        log_info "Unmounting $MOUNT..."
        sudo umount -l "$MOUNT" 2>/dev/null || sudo umount -f "$MOUNT" 2>/dev/null || log_warning "Failed to unmount $MOUNT"
    done
fi

# --- 4. Create Partition and Filesystem ---
log_step "4. CREATING PARTITION AND FILESYSTEM"
log_info "Creating partition table on $DEVICE..."

# Wipe existing data
log_info "Wiping existing data on $DEVICE..."
sudo wipefs -a "$DEVICE" 2>/dev/null || log_warning "Could not wipe filesystem signatures"
sudo dd if=/dev/zero of="$DEVICE" bs=1M count=10 2>/dev/null || log_warning "Could not zero out beginning of disk"

# Create GPT partition table
log_info "Creating GPT partition table..."
sudo parted -s "$DEVICE" mklabel gpt || log_error "Failed to create GPT partition table"

# Create partition (use 100% of disk)
log_info "Creating primary partition..."
sudo parted -s "$DEVICE" mkpart primary ext4 0% 100% || log_error "Failed to create partition"

# Wait for kernel to recognize partition
sleep 3

# Check if partition was created
if [ ! -e "$PARTITION" ]; then
    log_error "Partition $PARTITION was not created. Check disk and try again."
fi

log_info "Formatting $PARTITION as ext4..."
# Optimizations for Docker: 
# -i 8192: More inodes for many small files
# -m 0: No reserved blocks (for data partitions)
# -O ^has_journal: Disable journaling for better performance (optional)
sudo mkfs.ext4 -F -i 8192 -m 0 "$PARTITION" || log_error "Failed to format $PARTITION"

log_info "Filesystem created successfully on $PARTITION"

# --- 5. Mount New Partition and Copy Data ---
log_step "5. COPYING DATA TO NEW PARTITION"
log_info "Mounting new partition to $TEMP_MOUNT..."
sudo mkdir -p "$TEMP_MOUNT"
sudo mount "$PARTITION" "$TEMP_MOUNT" || log_error "Failed to mount $PARTITION to $TEMP_MOUNT"

# Calculate size and estimate time
log_info "Calculating data size..."
VAR_SIZE=$(sudo du -sb "$MOUNT_POINT" 2>/dev/null | cut -f1)
if [ -z "$VAR_SIZE" ]; then
    VAR_SIZE=0
fi

log_info "Total data to copy: $(echo "scale=2; $VAR_SIZE/1024/1024/1024" | bc) GB"
log_info "Starting data copy from $MOUNT_POINT to $TEMP_MOUNT..."
START_TIME=$(date +%s)

# Use rsync if available (better for large data)
if command -v rsync >/dev/null 2>&1; then
    log_info "Using rsync for efficient data transfer..."
    
    # Create exclude list
    EXCLUDE_LIST=(
        "--exclude=/var/run"
        "--exclude=/var/lock"
        "--exclude=/var/tmp"
        "--exclude=/var/cache/apt/archives"
        "--exclude=*.tmp"
        "--exclude=*.log"
    )
    
    sudo rsync -avxHAX --progress --stats \
          "${EXCLUDE_LIST[@]}" \
          "$MOUNT_POINT/" "$TEMP_MOUNT/" || log_error "Failed to copy data using rsync"
    
    log_info "Rsync completed"
else
    log_info "Using cp for data transfer..."
    log_warning "This may take a long time for large directories"
    
    # Create a list of directories to copy
    DIRS_TO_COPY=$(sudo ls -A "$MOUNT_POINT")
    
    for DIR in $DIRS_TO_COPY; do
        if [ "$DIR" != "run" ] && [ "$DIR" != "lock" ] && [ "$DIR" != "tmp" ]; then
            log_info "Copying $DIR..."
            sudo cp -a "$MOUNT_POINT/$DIR" "$TEMP_MOUNT/" 2>/dev/null || log_warning "Failed to copy $DIR"
        fi
    done
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))
log_info "Data copy completed in ${MINUTES}m ${SECONDS}s."

# Create required directories that were excluded
log_info "Creating required system directories..."
sudo mkdir -p "$TEMP_MOUNT"/{run,lock,tmp}
sudo chmod 1777 "$TEMP_MOUNT"/tmp
sudo chmod 1777 "$TEMP_MOUNT"/run

# --- 6. Verify Data Integrity ---
log_step "6. VERIFYING DATA INTEGRITY"
log_info "Verifying copied data..."

# Check file counts
log_info "Counting files in source and destination..."
SRC_FILES=$(sudo find "$MOUNT_POINT" -type f 2>/dev/null | wc -l)
DST_FILES=$(sudo find "$TEMP_MOUNT" -type f 2>/dev/null | wc -l)

log_info "Source files: $SRC_FILES"
log_info "Destination files: $DST_FILES"

# Check Docker data specifically
if [ -d "$DOCKER_DIR" ]; then
    log_info "Checking Docker data..."
    DOCKER_SRC=$(sudo find "$DOCKER_DIR" -type f 2>/dev/null | wc -l)
    DOCKER_DST=$(sudo find "$TEMP_MOUNT/lib/docker" -type f 2>/dev/null | wc -l)
    log_info "Docker files (source): $DOCKER_SRC"
    log_info "Docker files (destination): $DOCKER_DST"
fi

# Allow 10% difference due to exclusions
THRESHOLD=$((SRC_FILES * 90 / 100))
if [ "$DST_FILES" -lt "$THRESHOLD" ]; then
    log_warning "Significant file count mismatch!"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Aborting. Data remains on new partition at $TEMP_MOUNT"
        log_info "You can manually check: $TEMP_MOUNT"
        exit 1
    fi
fi

# --- 7. Switch to New Partition ---
log_step "7. SWITCHING TO NEW PARTITION"
log_info "Backing up old $MOUNT_POINT to $BACKUP_DIR..."

# Rename old /var
if [ -d "$MOUNT_POINT" ]; then
    if [ -d "$BACKUP_DIR" ]; then
        log_warning "$BACKUP_DIR already exists. Removing..."
        sudo rm -rf "$BACKUP_DIR"
    fi
    sudo mv "$MOUNT_POINT" "$BACKUP_DIR" || log_error "Failed to backup old $MOUNT_POINT"
    log_info "Old /var backed up to $BACKUP_DIR"
fi

# Create new /var directory
log_info "Creating new $MOUNT_POINT directory..."
sudo mkdir -p "$MOUNT_POINT"

# Unmount from temp and mount to /var
log_info "Remounting new partition to $MOUNT_POINT..."
sudo umount "$TEMP_MOUNT"
sudo mount "$PARTITION" "$MOUNT_POINT" || log_error "Failed to mount $PARTITION to $MOUNT_POINT"

# Remove temp mount point
sudo rmdir "$TEMP_MOUNT" 2>/dev/null || true

# --- 8. Update /etc/fstab ---
log_step "8. UPDATING /ETC/FSTAB"
log_info "Getting UUID for $PARTITION..."
UUID=$(sudo blkid -s UUID -o value "$PARTITION")
if [ -z "$UUID" ]; then
    log_error "Failed to get UUID for $PARTITION"
fi
log_info "UUID for $PARTITION: $UUID"

# Backup fstab
FSTAB_BACKUP="/etc/fstab.backup.$(date +%Y%m%d_%H%M%S)"
sudo cp /etc/fstab "$FSTAB_BACKUP"
log_info "Backed up fstab to $FSTAB_BACKUP"

# Remove any existing entries for /var
log_info "Removing old /var entries from fstab..."
sudo sed -i "\|^[^#].*[[:space:]]$MOUNT_POINT[[:space:]]|d" /etc/fstab

# Add new entry
FSTAB_ENTRY="UUID=$UUID $MOUNT_POINT ext4 defaults,noatime,nodiratime 0 1"
log_info "Adding new fstab entry:"
echo "$FSTAB_ENTRY"
echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab > /dev/null || log_error "Failed to update fstab"

log_info "/etc/fstab updated successfully"

# --- 9. Restart Services ---
log_step "9. RESTARTING SERVICES"
log_info "Restarting all services..."

# Function to start services
start_services() {
    log_info "Starting Docker services in correct order..."
    
    # Start docker service first
    if systemctl list-unit-files | grep -q "docker.service"; then
        log_info "Starting docker service..."
        sudo systemctl start docker || log_warning "Failed to start docker"
        sleep 5
    fi
    
    # Start docker.socket
    if systemctl list-unit-files | grep -q "docker.socket"; then
        log_info "Starting docker.socket..."
        sudo systemctl start docker.socket || log_warning "Failed to start docker.socket"
    fi
    
    # Check Docker status
    if systemctl is-active --quiet docker; then
        log_info "Docker is running"
        
        # Check Docker containers
        sleep 3
        CONTAINER_COUNT=$(docker ps -q 2>/dev/null | wc -l)
        log_info "Found $CONTAINER_COUNT Docker containers"
        
        # Try to start all containers
        if [ "$CONTAINER_COUNT" -eq 0 ]; then
            log_info "Starting all stopped containers..."
            docker start $(docker ps -aq) 2>/dev/null || log_warning "Some containers failed to start"
        fi
    else
        log_warning "Docker failed to start"
    fi
    
    # Start other services
    log_info "Starting other services..."
    for SERVICE in "${SERVICES_TO_STOP[@]}"; do
        if systemctl list-unit-files | grep -q "$SERVICE.service"; then
            log_info "Starting $SERVICE..."
            sudo systemctl start "$SERVICE" 2>/dev/null || log_warning "Failed to start $SERVICE"
        fi
    done
}

start_services

# --- 10. Final Verification ---
log_step "10. FINAL VERIFICATION"
log_info "Waiting for services to stabilize..."
sleep 10

echo -e "\n${BLUE}=== FINAL SYSTEM STATUS ===${NC}"

echo -e "\n${GREEN}Disk Usage:${NC}"
df -h "$MOUNT_POINT"

echo -e "\n${GREEN}Mount Status:${NC}"
mount | grep "$PARTITION"

echo -e "\n${GREEN}Docker Status:${NC}"
if command -v docker >/dev/null 2>&1; then
    docker info 2>/dev/null | grep -E "Server Version|Containers|Images|Storage Driver" || echo "Docker info not available"
    echo ""
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | head -10
fi

echo -e "\n${GREEN}Service Status:${NC}"
for SERVICE in "docker" "${SERVICES_TO_STOP[@]}"; do
    if systemctl list-unit-files | grep -q "$SERVICE.service"; then
        STATUS=$(systemctl is-active "$SERVICE" 2>/dev/null || echo "unknown")
        echo "$SERVICE: $STATUS"
    fi
done

echo -e "\n${GREEN}Data Verification:${NC}"
echo "Old /var backup: $BACKUP_DIR"
echo "New /var mount: $(df -h $MOUNT_POINT | tail -1 | awk '{print $1}')"
echo "UUID in fstab: $(grep "$MOUNT_POINT" /etc/fstab | grep -o 'UUID=[^ ]*' | head -1)"

# --- 11. Cleanup and Final Instructions ---
log_step "MIGRATION COMPLETE!"
log_info "================================================"
log_info "Migration completed successfully!"
log_info "================================================"

echo -e "\n${YELLOW}=== IMPORTANT INFORMATION ===${NC}"
echo "1. Old data is backed up at: ${BACKUP_DIR}"
echo "2. fstab backup: ${FSTAB_BACKUP}"
echo "3. New partition UUID: ${UUID}"
echo "4. Lock file removed: ${LOCK_CHECK_FILE}"

echo -e "\n${YELLOW}=== NEXT STEPS ===${NC}"
echo "1. Reboot the system to ensure everything mounts correctly:"
echo "   sudo reboot"
echo ""
echo "2. After reboot, verify:"
echo "   df -h /var"
echo "   docker ps"
echo "   systemctl status docker"
echo ""
echo "3. Test your applications thoroughly"
echo ""
echo "4. After 24-48 hours (if everything works), remove old backup:"
echo "   sudo rm -rf ${BACKUP_DIR}"
echo ""
echo "5. Consider optimizing Docker storage:"
echo "   Edit /etc/docker/daemon.json:"
cat << 'EOF'
   {
     "storage-driver": "overlay2",
     "storage-opts": [
       "overlay2.override_kernel_check=true",
       "overlay2.size=50G"
     ],
     "log-driver": "json-file",
     "log-opts": {
       "max-size": "10m",
       "max-file": "3"
     }
   }
EOF
echo ""
echo "6. To apply Docker changes: sudo systemctl restart docker"

echo -e "\n${YELLOW}=== TROUBLESHOOTING ===${NC}"
echo "If Docker containers fail to start:"
echo "1. Check container logs: docker logs [container_name]"
echo "2. Check Docker daemon logs: journalctl -u docker"
echo "3. Restart specific container: docker start [container_name]"
echo "4. If storage issues persist: docker system prune -a (WARNING: removes all unused data)"

echo -e "\n${GREEN}Migration completed at: $(date)${NC}"

exit 0
