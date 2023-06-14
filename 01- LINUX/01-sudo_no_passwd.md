# Enable sudo without prompting password

Replace `<username>` with your username:
```
NAME=<username>
```
```
echo -e "${NAME}\tALL=(ALL)\tNOPASSWD: ALL" | sudo tee -a /etc/sudoers.d/${NAME}  >/dev/null
```

Or:
```
sudo bash -c 'echo "<username>        ALL=(ALL)       NOPASSWD: ALL" > /etc/sudoers.d/<username>'
```