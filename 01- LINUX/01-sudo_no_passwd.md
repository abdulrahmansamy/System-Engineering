# Enable sudo without prompting password

Replace `<username>` with your username
```
sudo bash -c 'echo "<username>        ALL=(ALL)       NOPASSWD: ALL" > /etc/sudoers.d/<username>'
```
Or:
```
NAME=<username>
```
```
echo "${NAME}        ALL=(ALL)       NOPASSWD: ALL" | sudo tee /etc/sudoers.d/${NAME} 
```