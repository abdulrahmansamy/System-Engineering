# LVM Partitioning

## Install LVM packages

```bash
apt -y update && apt -y install lvm2 && apt -y install xfsprogs 

```

```bash
yum -y install lvm2 && yum -y install xfsprogs 
```



## Partitioning Variables

```bash
PVNAME=
```
```bash
VGNAME=
```
```bash
LVNAME=
```
```bash
MOUNTPOINT=
```

## Partitioning Variable for userdata
```bash
PVNAME=
VGNAME=
LVNAME=
MOUNTPOINT=
```


```bash
echo -e "Physical Volume Name\t= /dev/$PVNAME"
echo -e "Volume Group Name\t= $VGNAME"
echo -e "Logical Volume Name\t= $LVNAME"
echo -e "Mount Point Name\t= $MOUNTPOINT"
```




```bash

pvcreate /dev/$PVNAME
vgcreate $VGNAME /dev/$PVNAME

lvcreate -l 100%FREE -n $LVNAME $VGNAME
mkfs.xfs /dev/mapper/$VGNAME-$LVNAME
mkdir -p $MOUNTPOINT
mount /dev/mapper/$VGNAME-$LVNAME $MOUNTPOINT
grep $MOUNTPOINT /proc/mounts >> /etc/fstab

```


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
sudo umount /dev/mapper/$VGNAME-$LVNAME
# sudo mkfs -t ext4 /dev/mapper/$VGNAME-$LVNAME

sudo mkfs.ext4 -F /dev/mapper/$VGNAME-$LVNAME

sudo sed -i.bak "/$MOUNTPOINT/d" /etc/fstab ## Delete the old mount record

sudo sed -i.bak2 "/$LVNAME/d" /etc/fstab 



mount /dev/mapper/$VGNAME-$LVNAME $MOUNTPOINT 
grep $MOUNTPOINT /proc/mounts >> /etc/fstab

lsblk -f
df -hT

```


## Clear your footprint
```bash

history -c && history -w
```
or
```bash
history -c -w

```