#!/bin/bash
set -e 

# --- Logging Functions ---
log_info() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $1"
}

log_error() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] $1" >&2
    exit 1
}

# --- Check for Root ---
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run with root privileges (sudo)."
fi

# --- Variable Definitions ---
DEVICE="/dev/sdb"
PART_TARGET="${DEVICE}1"
TARGET_MOUNT="/home"

log_info "=== STARTING DISK MOUNT TO /home ==="

# 1. Cleanup old mounts
log_info "Cleaning up ${DEVICE}..."
umount ${DEVICE}* 2>/dev/null || true

# 2. Re-partition (Single Partition - 100%)
log_info "Creating GPT table and one 100% partition..."
parted -s "$DEVICE" mklabel gpt
parted -s "$DEVICE" mkpart primary ext4 0% 100%
sleep 2

# 3. Format Partition
log_info "Formatting ${PART_TARGET} to EXT4..."
mkfs.ext4 -F "$PART_TARGET"

# 4. Data Migration
log_info "Preparing migration for existing /home data..."
mkdir -p /mnt/tmp_home
mount "$PART_TARGET" /mnt/tmp_home

log_info "Copying current /home data to the new disk..."
# Using -a to preserve permissions, ownership (UID/GID), and timestamps
cp -a /home/. /mnt/tmp_home/ 2>/dev/null || true

# 5. Update /etc/fstab
log_info "Updating /etc/fstab for persistence..."
UUID=$(blkid -s UUID -o value "$PART_TARGET")
if [ -z "$UUID" ]; then
    log_error "Failed to get UUID for ${PART_TARGET}"
fi

# Remove old /home entries to prevent duplicates
sed -i "\|${TARGET_MOUNT}[[:space:]]|d" /etc/fstab

# Add new UUID-based entry
echo "UUID=${UUID} ${TARGET_MOUNT} ext4 defaults 0 2" >> /etc/fstab

# 6. Finalizing
log_info "Unmounting temporary path..."
umount /mnt/tmp_home

log_info "Mounting the new /home..."
mount -a

# 7. Verification
echo "------------------------------------------------"
log_info "Verification of New /home Capacity:"
df -h "$TARGET_MOUNT"

log_info "Process Complete! Your /home is now located on ${PART_TARGET}."
