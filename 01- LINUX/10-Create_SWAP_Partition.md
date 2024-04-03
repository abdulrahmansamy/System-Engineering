# Create SWAP Partition

```bash
SWAPDEVICE=sdb
```
```bash
fdisk -l /dev/$SWAPDEVICE
echo -e "n\np\n\n\n\nt\n82\nw" | fdisk /dev/$SWAPDEVICE
partprobe /dev/$SWAPDEVICE
mkswap /dev/$SWAPDEVICE
swapon /dev/$SWAPDEVICE
fdisk -l /dev/$SWAPDEVICE
```