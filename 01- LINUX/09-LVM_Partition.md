# LVM Partitioning

#### 1. Install LVM and fs packages 

##### - for `Debian/Ubuntu`
```bash
sudo apt -y update && sudo apt -y install lvm2 && sudo apt -y install xfsprogs e2fsprogs

```
##### - for `Red Hat/CentOS/Fedora`
```bash
sudo yum -y install lvm2 && sudo yum -y install xfsprogs e2fsprogs
```

##### - for `Suse`
```
zypper refresh
zypper -n in libudev-devel

zypper -n install lvm2
zypper -n install xfsprogs
zypper -n install e2fsprogs
```



<!-- ## Partitioning Variables

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
``` -->

#### 2. Partitioning Variable
```bash
PVNAME=<Physical Volume Name>
VGNAME=<Volume Group Name>
LVNAME=<Logical Volume Name>
MOUNTPOINT=<Mount Point>
```

##### Validate your variables

```bash
echo -e "Physical Volume Name\t= /dev/$PVNAME"
echo -e "Volume Group Name\t= $VGNAME"
echo -e "Logical Volume Name\t= $LVNAME"
echo -e "Mount Point Name\t= $MOUNTPOINT"
```

#### 3. Create the LVM Partition
```bash

pvcreate /dev/$PVNAME
vgcreate $VGNAME /dev/$PVNAME

lvcreate -l 100%FREE -n $LVNAME $VGNAME
# lvcreate  -Z n -l 100%FREE -n $LVNAME $VGNAME ##  in some cases the argument `-Z n` is required
mkfs.xfs /dev/mapper/$VGNAME-$LVNAME
mkdir -p $MOUNTPOINT
mount /dev/mapper/$VGNAME-$LVNAME $MOUNTPOINT
grep $MOUNTPOINT /proc/mounts >> /etc/fstab

```
##### Validating the partitions

```bash
pvs
vgs
lvs
lsblk -f
df -hT
```

##### All steps in One script for `userdata`

```bash
PVNAME=<Physical Volume Name>
VGNAME=<Volume Group Name>
LVNAME=<Logical Volume Name>
MOUNTPOINT=<Mount Point>
sudo apt -y update && sudo apt -y install lvm2 && sudo apt -y install xfsprogs e2fsprogs

pvcreate /dev/$PVNAME
vgcreate $VGNAME /dev/$PVNAME

lvcreate -l 100%FREE -n $LVNAME $VGNAME
# lvcreate  -Z n -l 100%FREE -n $LVNAME $VGNAME ##  in some cases the argument `-Z n` is required
mkfs.xfs /dev/mapper/$VGNAME-$LVNAME
mkdir -p $MOUNTPOINT
mount /dev/mapper/$VGNAME-$LVNAME $MOUNTPOINT
grep $MOUNTPOINT /proc/mounts >> /etc/fstab
```
<!-- 
```bash

apt -y update && apt -y install lvm2 && apt -y install xfsprogs 

pvcreate /dev/vdb
vgcreate vg_fidelis /dev/vdb

lvcreate -l 100%FREE -n lv_opt vg_fidelis
mkfs.xfs /dev/mapper/vg_fidelis-lv_opt
mkdir -p /opt/fidelis_endpoint
mount /dev/mapper/vg_fidelis-lv_opt /opt/fidelis_endpoint
grep /opt/fidelis_endpoint /proc/mounts >> /etc/fstab

``` -->



## Change the partition filesystem format

Take the variables from the previous section
#### 1. unmount the current mount
```bash
sudo umount /dev/mapper/$VGNAME-$LVNAME
```

#### 2. format with the required fs

##### for `ext4` filesystem
```bash
sudo mkfs.ext4 -F /dev/mapper/$VGNAME-$LVNAME
```
##### for `xfs` filesystem
```bash
sudo mkfs.xfs -f /dev/mapper/$VGNAME-$LVNAME
```
#### 3. Delete the old mount record
```bash
sudo sed -i.bak "\|$MOUNTPOINT|d" /etc/fstab  
```

#### 4. Mount the new fs
```bash
mount /dev/mapper/$VGNAME-$LVNAME $MOUNTPOINT 
grep $MOUNTPOINT /proc/mounts >> /etc/fstab
```
#### 5. Verify the current fs and mount point
```bash
lsblk -f | grep -B1 $MOUNTPOINT
df -hT | grep $MOUNTPOINT

```

<!-- # sudo mkfs -t ext4 /dev/mapper/$VGNAME-$LVNAME -->

####  6. Clear your footprint
```bash
history -c && history -w
```
or
```bash
history -c -w
```

#### All steps in One script

```bash
sudo umount /dev/mapper/$VGNAME-$LVNAME
sudo mkfs.ext4 -F /dev/mapper/$VGNAME-$LVNAME
sudo sed -i.bak "\|$MOUNTPOINT|d" /etc/fstab
mount /dev/mapper/$VGNAME-$LVNAME $MOUNTPOINT 
grep $MOUNTPOINT /proc/mounts >> /etc/fstab
```
