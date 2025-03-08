# Jumb Host Configuration - Create Users and Distribute Keys 

<!--
## in Jumb host - Create user and Generate key
```bash
user=<username>
sudo adduser --disabled-password --gecos "" $user
sudo mkdir -p /home/$user/.ssh
sudo ssh-keygen -t rsa -b 2048 -f /home/$user/.ssh/id_rsa -q -N ""
sudo chown -R $user:$user /home/$user/.ssh
```

download the pub key

## in the remote hosts - Create user and upload pub key
```bash
user=<username>
sudo adduser --disabled-password --gecos "" $user
sudo mkdir -p /home/$user/.ssh
sudo touch /home/$user/authorized_keys

sudo chown -R $user:$user /home/$user/.ssh
sudo chown -R $user:$user /home/$user/authorized_keys
```
upload pub key
```bash
cat key.pub >> /home/$user/authorized_keys
```
-->

```bash
ADMIN_USER=admin
DEV_USER=dev

SSH_KEY_PATH="/home/$DEV_USER/.ssh"
SSH_KEY="$SSH_KEY_PATH/id_rsa"
SSH_KEY_PUB="$SSH_KEY.pub"

REMOTE_HOSTS=("10.20.22.3" "10.20.21.3")
REMOTE_HOSTS=("10.20.22.3")
REMOTE_HOSTS=("172.16.42.161")

#LOCAL_USERS=("gotocme")
#REMOTE_USERS=("gotocme")
#REMOTE_USER="remoteadmin"

create_local_users_and_keys() {
    local user=$1

    echo "Creating local user $user"
	sudo useradd -m -s /bin/bash $user


    #sudo adduser --disabled-password --gecos "" $user
    sudo mkdir -p /home/$user/.ssh
    sudo ssh-keygen -t rsa -b 2048 -f /home/$user/.ssh/id_rsa -q -N ""
    sudo chown -R $user:$user /home/$user/.ssh
}



create_dev_user_in_remote_hosts() {
    local server=$1

    echo "Creating user $DEV_USER on $server"
    ssh $ADMIN_USER@$server "sudo useradd -m -s /bin/bash $DEV_USER"

    ssh $ADMIN_USER@$server "sudo mkdir -p $SSH_KEY_PATH"
    ssh $ADMIN_USER@$server "sudo chown -R $DEV_USER:$DEV_USER $SSH_KEY_PATH"
    ssh $ADMIN_USER@$server "sudo chmod 700 $SSH_KEY_PATH"
}

elevating_dev_user_in_remote_hosts() {
    echo "Elvating user permessions of $DEV_USER on $server"
    ssh $ADMIN_USER@$server 'echo -e "$DEV_USER\tALL=(ALL)\tNOPASSWD: ALL" | sudo tee -a /etc/sudoers.d/$DEV_USER  >/dev/null'

}

distribute_pub_key() {

	local server=$1
	echo "Copying public key to $DEV_USER@$server"
	ssh $ADMIN_USER@$server "echo '$(sudo cat $SSH_KEY_PUB)' | sudo tee -a /home/$DEV_USER/.ssh/authorized_keys &> /dev/null"
}

create_local_users_and_keys $DEV_USER

for server in "${REMOTE_HOSTS[@]}"; do
    create_dev_user_in_remote_hosts $server
done

for server in "${REMOTE_HOSTS[@]}"; do
    elevating_dev_user_in_remote_hosts $server
done

for server in "${REMOTE_HOSTS[@]}"; do
	distribute_pub_key $server
done

```