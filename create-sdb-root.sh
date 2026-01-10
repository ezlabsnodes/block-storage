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
    log_error "Script ini harus dijalankan sebagai root (sudo)."
fi

# --- Variable Definitions ---
DEVICE="/dev/sdb"
PART_TARGET="${DEVICE}1"
TARGET_MOUNT="/root"

log_info "=== MEMULAI PROSES MOUNT DISK BARU KE /root ==="

# 1. Membersihkan mount point lama jika ada
log_info "Membersihkan ${DEVICE}..."
umount ${DEVICE}* 2>/dev/null || true

# 2. Partisi Ulang (Single Partition - 100%)
log_info "Membuat tabel partisi GPT dan satu partisi tunggal..."
parted -s "$DEVICE" mklabel gpt
parted -s "$DEVICE" mkpart primary ext4 0% 100%
sleep 2

# 3. Format Partisi
log_info "Memformat ${PART_TARGET} ke EXT4..."
mkfs.ext4 -F "$PART_TARGET"

# 4. Migrasi Data
log_info "Menyiapkan migrasi data untuk /root..."
mkdir -p /mnt/tmp_root
mount "$PART_TARGET" /mnt/tmp_root

log_info "Menyalin data asli ke disk baru..."
# Menggunakan cp -a untuk menjaga permission dan owner
cp -a /root/. /mnt/tmp_root/ 2>/dev/null || true

# 5. Update /etc/fstab
log_info "Memperbarui /etc/fstab agar permanen..."
UUID=$(blkid -s UUID -o value "$PART_TARGET")
if [ -z "$UUID" ]; then
    log_error "Gagal mendapatkan UUID untuk ${PART_TARGET}"
fi

# Hapus entri lama untuk /root jika ada agar tidak double
sed -i "\|${TARGET_MOUNT}[[:space:]]|d" /etc/fstab

# Tambah entri baru
echo "UUID=${UUID} ${TARGET_MOUNT} ext4 defaults 0 2" >> /etc/fstab

# 6. Selesai
log_info "Melepas mount sementara..."
umount /mnt/tmp_root

log_info "Mengaktifkan disk baru ke /root..."
mount -a

# 7. Verifikasi
echo "------------------------------------------------"
log_info "Verifikasi Kapasitas /root Baru:"
df -h "$TARGET_MOUNT"

log_info "Proses Selesai! Sekarang /root berada di ${PART_TARGET}."
