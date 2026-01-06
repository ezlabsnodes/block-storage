#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

# --- Logging Functions ---
log_info() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $1"
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
MOUNT_POINT="/root"

log_info "Starting automatic partitioning, formatting, and mounting of ${DEVICE} to ${MOUNT_POINT}."
log_info "WARNING: All data on ${DEVICE} will be erased without confirmation."

# --- 1. Unmount the Device/Partition if Mounted ---
log_info "Attempting to unmount ${DEVICE} and any of its partitions if mounted..."
# Check for any mounted partitions of the device
if lsblk -no MOUNTPOINT "${DEVICE}" | grep -q '/'; then
    sudo umount "${DEVICE}"* 2>/dev/null || true # Try to unmount any partitions of sdb
    if mountpoint -q "$DEVICE"; then # Check if the device itself is mounted
        sudo umount "$DEVICE" || log_error "Failed to unmount ${DEVICE}."
    fi
    log_info "${DEVICE} or its partitions successfully unmounted."
else
    log_info "${DEVICE} is not currently mounted."
fi

# --- 2. Create a New Partition Table and Partition ---
log_info "Creating a new GPT partition table and a single primary partition on ${DEVICE}..."
# Use parted to create a GPT label and a single partition spanning the entire disk.
# -s for silent mode, mklabel gpt for GPT partition table, mkpart primary ext4 0% 100% for the partition.
echo "label: gpt
mkpart primary ext4 0% 100%" | sudo parted -s "$DEVICE" mklabel gpt mkpart primary ext4 0% 100% || log_error "Failed to create new partition on ${DEVICE}."
log_info "Partition ${PARTITION} successfully created."
sleep 2 # Give the kernel a moment to recognize the new partition

# --- 3. Format the Partition ---
log_info "Formatting ${PARTITION} with the ext4 filesystem..."
# -F forces overwriting any existing filesystem
sudo mkfs.ext4 -F "$PARTITION" || log_error "Failed to format ${PARTITION}."
log_info "Partition ${PARTITION} successfully formatted."

# --- 4. Handle Existing /root Directory ---
log_info "Handling existing ${MOUNT_POINT} directory..."
if [ -d "$MOUNT_POINT" ] && [ "$(ls -A $MOUNT_POINT)" ]; then
    log_info "Existing ${MOUNT_POINT} directory is not empty. Backing it up to ${MOUNT_POINT}_old."
    sudo mv "$MOUNT_POINT" "${MOUNT_POINT}_old" || log_error "Failed to backup ${MOUNT_POINT}."
elif [ -d "$MOUNT_POINT" ]; then
    log_info "Existing ${MOUNT_POINT} directory is empty or does not contain data to move. Proceeding."
fi

# Create the mount point directory if it doesn't exist
if [ ! -d "$MOUNT_POINT" ]; then
    log_info "Creating mount point directory ${MOUNT_POINT}..."
    sudo mkdir -p "$MOUNT_POINT" || log_error "Failed to create directory ${MOUNT_POINT}."
fi

# --- 5. Mount the Partition ---
log_info "Mounting ${PARTITION} to ${MOUNT_POINT}..."
sudo mount "$PARTITION" "$MOUNT_POINT" || log_error "Failed to mount ${PARTITION} to ${MOUNT_POINT}."
log_info "Partition ${PARTITION} successfully mounted to ${MOUNT_POINT}."

# --- 6. Update /etc/fstab for Permanent Mount ---
log_info "Getting UUID for ${PARTITION}..."
UUID=$(sudo blkid -s UUID -o value "$PARTITION")
if [ -z "$UUID" ]; then
    log_error "Failed to get UUID for ${PARTITION}."
fi
log_info "UUID for ${PARTITION}: ${UUID}"

FSTAB_ENTRY="UUID=${UUID} ${MOUNT_POINT} ext4 defaults 0 2"

log_info "Adding/updating entry in /etc/fstab..."
# Check if an entry for the mount point already exists
if grep -q "$MOUNT_POINT" /etc/fstab; then
    log_info "Entry for ${MOUNT_POINT} already exists in /etc/fstab. Updating the existing entry."
    sudo sed -i "s|.* ${MOUNT_POINT} .*|${FSTAB_ENTRY}|" /etc/fstab || log_error "Failed to update /etc/fstab."
else
    log_info "Adding a new entry to /etc/fstab."
    echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab > /dev/null || log_error "Failed to add entry to /etc/fstab."
fi
log_info "/etc/fstab successfully updated."

# --- 7. Verification ---
log_info "Verifying the results..."
sleep 2 # Give the system a moment to reflect changes
sudo lsblk "$DEVICE"
echo ""
sudo df -h "$MOUNT_POINT"

log_info "Process completed. ${PARTITION} is now formatted, mounted to ${MOUNT_POINT}, and configured for automatic mounting on boot."
log_info "If any data was in the old /root directory, it has been moved to ${MOUNT_POINT}_old."
