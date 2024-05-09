# Configure NTP client

### check the current situation
```bash
systemctl status chronyd.service

timedatectl

cat /etc/chrony.conf
```
### Update the confiration file
```bash
echo -e "server\t10.121.41.11\tiburst\nserver\t10.121.41.12\tiburst" > /etc/chrony.d/ntp.conf
```
or
```bash
echo -e "pool\t10.121.41.11\tiburst\npool\t10.121.41.12\tiburst" > /etc/chrony.d/ntp.conf
```

chech the configuration
```bash
cat /etc/chrony.d/ntp.conf
```

### Enable the configuration
```bash
systemctl restart chronyd.service
systemctl enable chronyd.service
```

### Check the configuration takes effect

```bash
systemctl status chronyd.service

timedatectl set-local-rtc 0

sleep 10

timedatectl ; echo ; hwclock ; echo ; date

chronyc sources

chronyc sources -v

```











history -c

