# Enable ssh service

## For ubuntu
```
sudo apt-get update
sudo apt-get install -y openssh-server
sudo systemctl enable ssh.service --now
sudo systemctl status ssh.service
```

## For RHEL/Centos/fedora
```
sudo yum install -y openssh-server
sudo systemctl enable sshd.service --now
sudo systemctl status sshd.service
```

## ssh login
```
ssh <username>@<public_IP> -p22
```
