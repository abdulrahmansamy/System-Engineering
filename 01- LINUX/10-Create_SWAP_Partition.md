# Create SWAP Partition

### Determine the `SWAP` device name:
```bash
lsblk -f
```
Add the `SWAP` device name:
```bash
SWAPDEVICE=<sdb>
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
### Validate the configured `SWAP` device
```bash
swapon -s
free -m

grep SwapTotal /proc/meminfo

lsblk -f
```

Straight forward script
```bash
fdisk -l /dev/sdb
echo -e "n\np\n\n\n\nt\n82\nw" | fdisk /dev/sdb
partprobe /dev/sdb
mkswap /dev/sdb1
swapon /dev/sdb1
fdisk -l /dev/sdb
```