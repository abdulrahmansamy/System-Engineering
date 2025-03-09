# Creating Bootable USB Drives

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [USB Drive Preparation](#usb-drive-preparation)
3. [Creating Linux Boot Drives](#creating-linux-boot-drives)
4. [Creating Windows Boot Drives](#creating-windows-boot-drives)
5. [Verification](#verification)
6. [Troubleshooting](#troubleshooting)

## Prerequisites
### Required Items
- USB drive (minimum 8GB)
- ISO image
- Administrative privileges

### Verification Tools
```bash
# Download and verify checksum (example for Fedora)
wget https://download.fedoraproject.org/pub/fedora/linux/releases/39/Workstation/x86_64/iso/Fedora-Workstation-39-x86_64-CHECKSUM
sha256sum -c Fedora-Workstation-39-x86_64-CHECKSUM --ignore-missing
```

## USB Drive Preparation
### Device Identification
```bash
# macOS
diskutil list

# Linux
lsblk
sudo fdisk -l
```

### Drive Formatting
#### For Linux ISOs
```bash
# macOS
diskutil eraseDisk JHFS+ "LINUX" GPT /dev/diskN

# Linux
sudo mkfs.ext4 -L "LINUX" /dev/sdX
```

#### For Windows ISOs
```bash
# macOS
diskutil eraseDisk MS-DOS "WINDOWS" GPT /dev/diskN

# Linux (FAT32)
sudo mkfs.vfat -F 32 -n "WINDOWS" /dev/sdX

# Linux (exFAT for large ISOs)
sudo mkfs.exfat -n "WINDOWS" /dev/sdX
```

## Creating Linux Boot Drives
### Using dd Command
```bash
# macOS
diskutil unmountDisk /dev/diskN
sudo dd if=/path/to/linux.iso of=/dev/diskN bs=1m status=progress

# Linux
sudo dd if=/path/to/linux.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

## Creating Windows Boot Drives
### Using WoeUSB
```bash
# Install WoeUSB
## Debian/Ubuntu
sudo apt install woeusb

## RHEL/Fedora
sudo dnf install WoeUSB

# Create bootable USB
sudo woeusb --target-filesystem NTFS \
            --device windows.iso /dev/sdX
```

## Verification
### System Checks
```bash
# Sync writes
sync

# Verify disk structure
sudo fdisk -l /dev/sdX

# Check filesystem
sudo fsck.vfat /dev/sdX1  # FAT32
sudo fsck.exfat /dev/sdX1 # exFAT
```

### Boot Testing
1. Safe ejection procedure
2. UEFI/BIOS boot menu access
3. Media verification option
4. Test boot process

## Troubleshooting
### Common Issues
```bash
# Permission fixes
sudo chmod 666 /dev/sdX

# Unmount busy device
sudo umount -f /dev/sdX*

# Write protection
sudo hdparm -r0 /dev/sdX
```

## Best Practices
1. Always verify checksums
2. Double-check device identifier
3. Never interrupt write process
4. Use progress monitoring
5. Test in target system
6. Keep backups of important data

## Quick Reference
### Speed Optimization
- Linux: `bs=4M`
- macOS: `bs=1m`
- Add `status=progress`
- Use `oflag=sync` for reliability

### Disk Formats
- Linux: ext4/FAT32
- Windows: FAT32/exFAT
- UEFI: FAT32 required
- Large ISOs (>4GB): exFAT