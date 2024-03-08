# Adding records to `hosts` file

## Adding records to `hosts` file as enteractive script
```bash
echo -e "please enter the IP"
read IP
echo -e "please enter the FQDN of the hostname"
read FQDN
echo -e "The record: "
echo -e "$IP\t$FQDN\t$(echo $FQDN | awk -F'.' '{print $1}')" | sudo tee -a /etc/hosts
if [ $? -eq 0 ] ; then 
    echo -e "Has been added to the hosts file"
else
    echo -e "Cannot be added to the hosts file"
fi
```

## Adding records using `VARIABLES`
```bash
IP=<Add your IP here>
```
```bash
FQDN=<Add your FQDN of the hostname>
```
```bash
sudo echo -e "$IP\t$FQDN\t$(echo $FQDN | awk -F'.' '{print $1}')" | sudo tee -a /etc/hosts
```

## Adding current hostname
```bash
IP=<Add your IP here>
```
```bash
sudo echo -e "$IP\t$(hostname)\t$(hostname | awk -F'.' '{print $1}')" | sudo tee -a /etc/hosts
```