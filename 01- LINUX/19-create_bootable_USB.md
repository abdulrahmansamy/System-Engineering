# Creating Bootable USB Drives for Linux Distributions

## Prerequisites
- USB drive (minimum 8GB recommended)
- ISO image of desired Linux distribution
- Administrative/sudo privileges

## Preparation Steps

### 1. Download Verification (Optional but Recommended)
```bash
# Download checksum file
wget https://download.fedoraproject.org/pub/fedora/linux/releases/39/Workstation/x86_64/iso/Fedora-Workstation-39-x86_64-CHECKSUM

# Verify ISO integrity
sha256sum -c Fedora-Workstation-39-x86_64-CHECKSUM --ignore-missing
```

### 2. Identify USB Drive

#### macOS
```bash
# List all disks
diskutil list

# Expected output format:
# /dev/disk0 (internal):
# /dev/disk2 (external, physical):
#   #:     TYPE NAME         SIZE
#   0:     FDisk_partition_scheme *8.0 GB
```

#### Linux
```bash
# List block devices
lsblk

# or using fdisk
sudo fdisk -l

# Expected output format:
# sda      8:0    0 931.5G  0 disk
# sdb      8:16   1   7.5G  0 disk  <- USB drive
```

## Creating Bootable USB

### macOS Method
```bash
# 1. Unmount disk (replace disk2 with your USB device)
diskutil unmountDisk /dev/disk2

# 2. Create bootable USB (showing progress)
sudo dd if=/path/to/distro.iso of=/dev/disk2 bs=1m status=progress

# Alternative with pv for progress monitoring
brew install pv
pv /path/to/distro.iso | sudo dd of=/dev/disk2 bs=1m
```

### Linux Method
```bash
# 1. Unmount if mounted
sudo umount /dev/sdb*

# 2. Create bootable USB (showing progress)
sudo dd if=/path/to/distro.iso of=/dev/sdb bs=4M status=progress oflag=sync
```

## Verification Steps

### 1. Check Write Completion
```bash
# Force sync of write buffers
sync

# macOS: Verify disk
diskutil verifyDisk /dev/disk2

# Linux: Check partition table
sudo fdisk -l /dev/sdb
```

### 2. Test USB Boot Integrity
- Safely eject the USB drive
- Boot from USB in test mode (if available)
- Run media verification if provided by distro

## Troubleshooting

### Common Issues and Solutions

1. Permission Denied
```bash
# macOS
sudo chown $(whoami):staff /dev/disk2

# Linux
sudo chmod 666 /dev/sdb
```

2. Device Busy
```bash
# Check what's using the device
lsof | grep /dev/sdb

# Force unmount if needed
sudo umount -f /dev/sdb*
```

3. Write Protection
```bash
# Check write protection status (Linux)
cat /sys/class/block/sdb/ro

# Disable write protection (if possible)
sudo hdparm -r0 /dev/sdb
```

## Safety Notes
- Double-check device identifier before writing
- Never use the dd command on system disk
- Keep terminal open until process completes
- Always verify checksum before writing
- Use status=progress to monitor operation

## Additional Tips
- Use `bs=4M` for faster writes on Linux
- Consider using `oflag=sync` for reliable writes
- Keep USB drive formatted as FAT32 for UEFI boot
- Test USB in multiple systems if possible