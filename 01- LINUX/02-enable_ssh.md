# Enable ssh service

## For ubuntu
```
sudo apt-get update
sudo apt-get install -y openssh-server
sudo systemctl enable ssh.service --now
sudo systemctl status ssh.service
```

## For RHEL/Centos/Fedora
```
sudo yum install -y openssh-server
sudo systemctl enable sshd.service --now
sudo systemctl status sshd.service
```

## ssh login
```
ssh <username>@<public_IP> -p22
```

## Disable Root SSH login

Edit the sshd configuration file
```
sudo vim /etc/ssh/sshd_config
```
Change this Parameter to:
```
PermitRootLogin no
```
Or, to allow root using `Public Keys`
```
PermitRootLogin prohibit-password
```
Save, and restart the service
```
sudo systemctl restart sshd.service
```