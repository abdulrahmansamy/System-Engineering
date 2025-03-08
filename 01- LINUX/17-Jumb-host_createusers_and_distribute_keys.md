# Jump Host Configuration Guide - User Management and SSH Key Distribution

## Overview
This guide provides automated scripts for:
- Creating users on jump host and remote servers
- Generating and distributing SSH keys
- Configuring sudo access for developers

## Prerequisites
- Administrative access to jump host
- SSH access to remote hosts
- Sudo privileges on all servers

## Configuration Variables
```bash
# User Configuration
ADMIN_USER=admin        # Existing admin user with SSH access
DEV_USER=dev           # New developer username to be created

# SSH Configuration
SSH_KEY_PATH="/home/$DEV_USER/.ssh"
SSH_KEY="$SSH_KEY_PATH/id_rsa"
SSH_KEY_PUB="$SSH_KEY.pub"

# Target Servers (modify as needed)
REMOTE_HOSTS=("10.20.22.3" "10.20.21.3")
```

## Implementation Functions

### 1. Local User Creation
```bash
create_local_users_and_keys() {
    local user=$1
    echo "Creating local user $user on jump host"
    sudo useradd -m -s /bin/bash $user
    
    # Setup SSH directory and keys
    sudo mkdir -p /home/$user/.ssh
    sudo ssh-keygen -t rsa -b 2048 -f /home/$user/.ssh/id_rsa -q -N ""
    sudo chown -R $user:$user /home/$user/.ssh
    sudo chmod 700 /home/$user/.ssh
}
```

### 2. Remote User Setup
```bash
create_dev_user_in_remote_hosts() {
    local server=$1
    echo "Creating user $DEV_USER on $server"
    
    # Create user and SSH directory
    ssh $ADMIN_USER@$server "sudo useradd -m -s /bin/bash $DEV_USER"
    ssh $ADMIN_USER@$server "sudo mkdir -p $SSH_KEY_PATH"
    
    # Set permissions
    ssh $ADMIN_USER@$server "sudo chown -R $DEV_USER:$DEV_USER $SSH_KEY_PATH"
    ssh $ADMIN_USER@$server "sudo chmod 700 $SSH_KEY_PATH"
}

elevating_dev_user_in_remote_hosts() {
    local server=$1
    echo "Configuring sudo access for $DEV_USER on $server"
    ssh $ADMIN_USER@$server "sudo bash -c 'echo \"$DEV_USER ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/$DEV_USER'"
    ssh $ADMIN_USER@$server "sudo chmod 440 /etc/sudoers.d/$DEV_USER"
}

distribute_pub_key() {
    local server=$1
    echo "Deploying SSH key for $DEV_USER@$server"
    ssh $ADMIN_USER@$server "sudo mkdir -p $SSH_KEY_PATH"
    ssh $ADMIN_USER@$server "echo '$(sudo cat $SSH_KEY_PUB)' | sudo tee $SSH_KEY_PATH/authorized_keys > /dev/null"
    ssh $ADMIN_USER@$server "sudo chown -R $DEV_USER:$DEV_USER $SSH_KEY_PATH"
    ssh $ADMIN_USER@$server "sudo chmod 600 $SSH_KEY_PATH/authorized_keys"
}
```

## Execution
```bash
# Step 1: Create local user and generate keys
create_local_users_and_keys $DEV_USER

# Step 2: Setup remote hosts
for server in "${REMOTE_HOSTS[@]}"; do
    create_dev_user_in_remote_hosts $server
    elevating_dev_user_in_remote_hosts $server
    distribute_pub_key $server
done
```

## Security Considerations
- All SSH directories should have 700 permissions
- SSH keys should have 600 permissions
- Regularly audit sudo access
- Consider using SSH key passphrase for additional security
- Monitor /etc/sudoers.d/ for unauthorized changes

## Verification Steps
1. Test SSH access: `ssh $DEV_USER@remote-host`
2. Verify sudo access: `sudo -l`
3. Check SSH key permissions: `ls -la ~/.ssh/`
4. Validate authorized_keys: `cat ~/.ssh/authorized_keys`
