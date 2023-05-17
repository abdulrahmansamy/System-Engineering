# Enable sudo without prompting password

```
sudo bash -c 'echo "username        ALL=(ALL)       NOPASSWD: ALL" > /etc/sudoers.d/username'
```