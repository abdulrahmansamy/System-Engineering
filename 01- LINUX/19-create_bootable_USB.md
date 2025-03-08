# Creating a Bootable Fedora USB Drive on macOS or Linux

This guide explains how to create a bootable Fedora USB drive without using any third-party tools.

## Prerequisites
- A USB drive (minimum 8GB)
- Fedora ISO image downloaded
- Administrative privileges

## Step-by-Step Instructions

### 1. Identify Your USB Drive
First, list all connected drives to identify your USB device:
```bash
diskutil list
```
Look for your USB drive in the output. It will be listed as `/dev/diskN` where N is a number.

### 2. Unmount the USB Drive
Before writing the ISO, unmount the USB drive (replace disk2 with your disk number):
```bash
diskutil unmountDisk /dev/disk2
```

### 3. Write the ISO to USB
Use the dd command to write the ISO file to your USB drive:
```bash
sudo dd if=~/Downloads/Fedora-Workstation-Live-x86_64-41-1.4.iso of=/dev/disk2 bs=1m
```

### Important Notes:
- Replace `~/Downloads/Fedora-Workstation-Live-x86_64-41-1.4.iso` with your ISO file path
- Replace `/dev/disk2` with your USB drive identifier
- The process may take several minutes
- No progress bar will be shown during the operation
- When completed, you'll see a summary of the data transfer

## Warning
⚠️ Be extremely careful with the `dd` command and double-check the output device (`of=`) as it will overwrite all data on the target drive!