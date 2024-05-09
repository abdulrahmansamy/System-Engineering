# Create SWAP Partition

### Determine the `SWAP` device name:
```bash
lsblk -f
```
Add the `SWAP` device name:
```bash
SWAPDEVICE=<'sdb' for example>
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

### Add `fstab` entry for `SWAP`
```bash
if sudo fdisk -l /dev/$SWAPDEVICE | grep -qi "nvme"; then
    echo "====> Adding fstab entry for NVMe device"
    echo -e "UUID=`sudo blkid  /dev/${SWAPDEVICE}p1 -o value -s UUID`\tswap\tswap\tdefault\t0 0" | sudo tee -a /etc/fstab &> /dev/null 
  else
    echo "====> Adding fstab entry for non-NVMe device"
    echo -e "UUID=`sudo blkid  /dev/${SWAPDEVICE}1 -o value -s UUID`\tswap\tswap\tdefault\t0 0" | sudo tee -a /etc/fstab &> /dev/null 
fi

swapon -a
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

echo -e "UUID=`sudo blkid  /dev/sdb1 -o value -s UUID`\tswap\tswap\tdefault\t0 0" | sudo tee -a /etc/fstab &> /dev/null 
swapon -a
```