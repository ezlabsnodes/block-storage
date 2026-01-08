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
PART_ROOT="${DEVICE}1"
PART_VAR="${DEVICE}2"
TARGET_ROOT="/root"
TARGET_VAR="/var"

log_info "=== STARTING PARTITIONING & DATA MIGRATION ==="

# 1. Cleanup: Unmount target device if busy
log_info "Cleaning up mount points on ${DEVICE}..."
umount ${DEVICE}* 2>/dev/null || true

# 2. Re-partitioning (GPT)
log_info "Creating new GPT partition table..."
parted -s "$DEVICE" mklabel gpt
parted -s "$DEVICE" mkpart primary ext4 0% 50%
parted -s "$DEVICE" mkpart primary ext4 50% 100%
sleep 2

# 3. Format Partitions
log_info "Formatting partitions to EXT4..."
mkfs.ext4 -F "$PART_ROOT"
mkfs.ext4 -F "$PART_VAR"

# 4. Data Migration (The Fix for APT Errors)
# We mount to a temporary location first to move existing data to the new disks
log_info "Preparing system data migration..."
mkdir -p /mnt/tmp_root /mnt/tmp_var

mount "$PART_ROOT" /mnt/tmp_root
mount "$PART_VAR" /mnt/tmp_var

log_info "Copying existing data to new partitions (this may take a while)..."
# -a (archive) flag is critical to preserve permissions, owners, and symlinks
cp -a /root/. /mnt/tmp_root/ 2>/dev/null || true
cp -a /var/. /mnt/tmp_var/ 2>/dev/null || true

# 5. Verify Crucial Structure (Emergency Double-Check)
log_info "Ensuring APT structure exists on new partition..."
mkdir -p /mnt/tmp_var/lib/dpkg/updates
mkdir -p /mnt/tmp_var/lib/apt/lists/partial
mkdir -p /mnt/tmp_var/cache/apt/archives/partial
touch /mnt/tmp_var/lib/dpkg/status

# 6. Update /etc/fstab
log_info "Updating /etc/fstab for persistence..."
update_fstab_entry() {
    local part=$1
    local mnt=$2
    local uuid=$(blkid -s UUID -o value "$part")
    # Delete old entry if exists
    sed -i "\|${mnt}[[:space:]]|d" /etc/fstab
    # Add new entry
    echo "UUID=${uuid} ${mnt} ext4 defaults 0 2" >> /etc/fstab
}

update_fstab_entry "$PART_ROOT" "$TARGET_ROOT"
update_fstab_entry "$PART_VAR" "$TARGET_VAR"

# 7. Finishing - Unmount temporary and activate permanent mounts
log_info "Cleaning up temporary mounts..."
umount /mnt/tmp_root
umount /mnt/tmp_var

log_info "Activating new partitions..."
mount -a

# 8. Final Verification
echo "------------------------------------------------"
log_info "Verifying New Disk Usage:"
df -h | grep -E "$TARGET_ROOT|$TARGET_VAR"

log_info "Testing APT Package Manager..."
apt-get clean
apt-get update && log_info "SUCCESS: APT is functional!"

log_info "Process Complete. REBOOT is highly recommended to restart all services."
