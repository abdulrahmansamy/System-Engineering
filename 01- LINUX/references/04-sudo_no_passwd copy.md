# Enable sudo without prompting password

Replace `<username>` with the required username:
```
sudo bash -c 'echo "<username>        ALL=(ALL)       NOPASSWD: ALL" > /etc/sudoers.d/<username>'
```

Or:
```
NAME=<username>
```
```
echo -e "${NAME}\tALL=(ALL)\tNOPASSWD: ALL" | sudo tee -a /etc/sudoers.d/${NAME}  >/dev/null
```


Or to elevate the current user:
```
echo -e "$(id -un)\tALL=(ALL)\tNOPASSWD: ALL" | sudo tee -a /etc/sudoers.d/$(id -un)  >/dev/null
```


<!-- 

```
sudo bash -c 'echo "$(id -un)       ALL=(ALL)       NOPASSWD: ALL" > /etc/sudoers.d/$(id -un)'
```
```
sudo bash -c 'NAME=`id -un` && echo "$NAME       ALL=(ALL)       NOPASSWD: ALL" > /etc/sudoers.d/$NAME'
```
 -->