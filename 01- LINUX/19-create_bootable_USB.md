# Create a Bootable Fedora USB Using a Mac or Linux Machine without any external tools

## 
```
diskutil list
```
```
diskutil unmountDisk /dev/disk2
```
```
sudo dd if=~/Downloads/Fedora-Workstation-Live-x86_64-41-1.4.iso of=/dev/disk2 bs=1m
```