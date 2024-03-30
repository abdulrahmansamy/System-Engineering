
## partitioning  as userdata

```bash

apt -y update && apt -y install lvm2 && apt -y install xfsprogs 

pvcreate /dev/vdb
vgcreate vg_fidelis /dev/vdb

lvcreate -l 100%FREE -n lv_opt vg_fidelis
mkfs.xfs /dev/mapper/vg_fidelis-lv_opt
mkdir -p /opt/fidelis_endpoint
mount /dev/mapper/vg_fidelis-lv_opt /opt/fidelis_endpoint
grep /opt/fidelis_endpoint /proc/mounts >> /etc/fstab

```

### Validating the partitions

```bash

pvs
vgs
lvs
lsblk -f
df -hT
```

## Change the partition filesystem format
```bash
sudo umount /dev/mapper/vg_fidelis-lv_opt
# sudo mkfs -t ext4 /dev/mapper/vg_fidelis-lv_opt

sudo mkfs.ext4 -F /dev/mapper/vg_fidelis-lv_opt

sudo sed -i.bak '/fidelis_endpoint/d' /etc/fstab
mount /dev/mapper/vg_fidelis-lv_opt /opt/fidelis_endpoint
grep /opt/fidelis_endpoint /proc/mounts >> /etc/fstab
lsblk -f
df -hT

```


## Clear your footprint
```bash

history -c && history -w

history -c -w

```