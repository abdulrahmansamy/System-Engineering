# Terminate Remote SSH Sessions

Discover who is connecting to your system:
```
who
```
Output:
```
user     pts/0        2021-08-28 11:17 (xxx.xxx.xxx.xxx)
root     pts/1        2021-08-28 12:00 (xxx.xxx.xxx.xxx)
```

Disconnect the root session `pts/1`:
```
sudo pkill -9 -t pts/1

```

# History of the ssh sessions

```
last -a
```

```
w
```

https://solci.eu/6-commands-to-check-and-list-active-ssh-connections-in-linux-connections-in-general/