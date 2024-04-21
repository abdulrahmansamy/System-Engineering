# Create SWAP Partition

### determine the `SWAP` device name:
```bash
lsblk -f
```
```bash
SWAPDEVICE=sdb
```
### Check the current status of the `SWAP` device:
```bash
sudo fdisk -l /dev/$SWAPDEVICE
```

### Configure the `SWAP` device:
```bash
sudo echo -e "n\np\n\n\n\nt\n82\nw" | sudo fdisk /dev/$SWAPDEVICE
sudo partprobe /dev/$SWAPDEVICE

if sudo fdisk -l /dev/$SWAPDEVICE | grep -qi "nvme"; then
    echo "====> NVMe device"
    sudo mkswap /dev/${SWAPDEVICE}p1
    sudo swapon /dev/${SWAPDEVICE}p1
  else
    echo "====> non-NVMe device"
    sudo mkswap /dev/${SWAPDEVICE}1
    sudo swapon /dev/${SWAPDEVICE}1
fi
```
### Validate the configured swap device
```bash
swapon -s
free -m

grep SwapTotal /proc/meminfo

lsblk -f
```

```bash
fdisk -l /dev/$SWAPDEVICE
echo -e "n\np\n\n\n\nt\n82\nw" | fdisk /dev/$SWAPDEVICE
partprobe /dev/$SWAPDEVICE
mkswap /dev/$SWAPDEVICE
swapon /dev/$SWAPDEVICE
fdisk -l /dev/$SWAPDEVICE
```