# Enable sudo without prompting password

Replace `<username>` with your username
```
sudo bash -c 'echo "<username>        ALL=(ALL)       NOPASSWD: ALL" > /etc/sudoers.d/<username>'
```
Or:
```
USER01=<username>
echo "${USER01}        ALL=(ALL)       NOPASSWD: ALL" | sudo tee /etc/sudoers.d/${USER01} 
```