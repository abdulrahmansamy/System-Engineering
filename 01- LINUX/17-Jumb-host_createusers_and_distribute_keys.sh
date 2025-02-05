gotocme

user=gotocme2
GROUP_NAME="dev"
sudo groupadd $GROUP_NAME
sudo useradd -m -G $GROUP_NAME $user
#sudo adduser --disabled-password --gecos "" $user
sudo mkdir -p /home/$user/.ssh
sudo ssh-keygen -t rsa -b 2048 -f /home/$user/.ssh/id_rsa -q -N ""
sudo chown -R $user:$user /home/$user/.ssh




user=gotocme2
GROUP_NAME="dev"
sudo groupadd $GROUP_NAME
#sudo adduser --disabled-password --gecos "" $user
sudo useradd -m -G $GROUP_NAME $user
sudo mkdir -p /home/$user/.ssh
sudo touch /home/$user/.ssh/authorized_keys

sudo chown -R $user:$user /home/$user/.ssh



cat key.pub >> /home/$user/authorized_keys

055

user=gotocme
sudo deluser $user sudo




ssh-keygen -t rsa -b 2048 -f ~/.ssh/cooplanner_gotocme -q -N ""

Load key "/home/user/.ssh/id_rsa": Permission denied
user@xxx.xxx.xxx.xxx: Permission denied (publickey)


sudo groupadd dev

sudo usermod $DEV_USER -G dev



-------------------------------------------------------------------


ADMIN_USER=asamy
DEV_USER=gotocme

SSH_KEY_PATH="/home/$DEV_USER/.ssh"
SSH_KEY="$SSH_KEY_PATH/id_rsa"
SSH_KEY_PUB="$SSH_KEY.pub"

REMOTE_HOSTS=("10.20.22.3" "10.20.21.3")
#REMOTE_HOSTS=("172.16.42.161")

sudo groupadd dev

create_local_users_and_keys() {
    local user=$1

    echo "Creating local user $user"
	sudo useradd -m -s /bin/bash $user
 	sudo usermod $user -G dev

    #sudo adduser --disabled-password --gecos "" $user
    sudo mkdir -p /home/$user/.ssh
    sudo ssh-keygen -t rsa -b 4096 -f /home/$user/.ssh/id_rsa -q -N 'aSNzPq&%6xagJ!t2'
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
	distribute_pub_key $server
done



cat coorplanner_gotocme.pub | sudo tee -a /home/$DEV_USER/.ssh/authorized_keys
sudo chown -R $DEV_USER:$DEV_USER /home/$DEV_USER/.ssh/authorized_keys






-------------------------------------------------------------------






create_remote_users() {
    local user=$1
    sudo adduser --disabled-password --gecos "" $user
    sudo mkdir -p /home/$user/.ssh
    sudo touch /home/$user/.ssh/authorized_keys
    sudo chown -R $user:$user /home/$user/.ssh

}


create_local_users_and_keys $DEV_USER

create_remote_users $DEV_USER


for RH in "${REMOTE_HOSTS[@]}"; do
	distribute_pub_key $RH
done










ssh-copy-id -i /home/$user/.ssh/id_rsa.pub $REMOTE_USER@$REMOTE_HOST

ssh-copy-id -i /home/gotocme/.ssh/id_rsa.pub gotocme@172.16.42.161

user=gotocme
cat ~/.ssh/id_rsa.pub
ssh asamy@172.16.42.161 "echo '$(cat ~/.ssh/id_rsa.pub)' > ~/authorized_keys"
ssh asamy@172.16.42.161 "cat ~/authorized_keys"
ssh asamy@172.16.42.161 "sudo cat ~/authorized_keys >> /home/$user/.ssh/authorized_keys"

ssh asamy@172.16.42.161 "cat ~/authorized_keys | sudo tee -a /home/$user/.ssh/authorized_keys &> /dev/null"

ssh asamy@172.16.42.161 "echo '$(cat ~/.ssh/id_rsa.pub)' | sudo tee -a /home/$user/.ssh/authorized_keys &> /dev/null"



ssh adminuser@xxx.xxx.xxx.xxx "cat ~/authorized_keys | sudo tee -a /home/$user/.ssh/authorized_keys &> /dev/null"
bash: line 1: /home/gotocme/.ssh/authorized_keys: Permission denied

for user in "${LOCAL_USERS[@]}"; do
    create_local_users_and_keys $user
done