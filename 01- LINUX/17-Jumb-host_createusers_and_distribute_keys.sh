#!/bin/bash

# Configuration Variables
ADMIN_USER=admin        # Existing admin user with SSH access
DEV_USER=dev           # New developer username to be created
GROUP_NAME="dev"       # Group name for developers
SSH_KEY_PATH="/home/$DEV_USER/.ssh"
SSH_KEY="$SSH_KEY_PATH/id_rsa"
SSH_KEY_PUB="$SSH_KEY.pub"

# List of remote hosts to configure
REMOTE_HOSTS=("10.20.22.3" "10.20.21.3")

# Error handling
set -e  # Exit on error
trap 'echo "Error on line $LINENO"' ERR

# Function to log messages with timestamp
log_message() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Function to check if command succeeded
check_success() {
    if [ $? -eq 0 ]; then
        log_message "SUCCESS: $1"
    else
        log_message "ERROR: $1"
        exit 1
    fi
}

# Function to create developer group
create_dev_group() {
    log_message "Creating developer group: $GROUP_NAME"
    sudo groupadd $GROUP_NAME 2>/dev/null || true
    check_success "Group creation"
}

# Function to create local user and generate SSH keys
create_local_users_and_keys() {
    local user=$1
    log_message "Creating local user: $user"
    
    # Create user and add to dev group
    sudo useradd -m -s /bin/bash $user
    sudo usermod $user -G $GROUP_NAME
    
    # Setup SSH directory and keys
    log_message "Generating SSH keys for $user"
    sudo mkdir -p /home/$user/.ssh
    sudo ssh-keygen -t rsa -b 4096 -f /home/$user/.ssh/id_rsa -q -N 'aSNzPq&%6xagJ!t2'
    sudo chown -R $user:$user /home/$user/.ssh
    sudo chmod 700 /home/$user/.ssh
    sudo chmod 600 /home/$user/.ssh/id_rsa
    
    check_success "Local user setup"
}

# Function to create user on remote hosts
create_dev_user_in_remote_hosts() {
    local server=$1
    log_message "Setting up user $DEV_USER on $server"
    
    # Create user and SSH directory
    ssh $ADMIN_USER@$server "sudo useradd -m -s /bin/bash $DEV_USER"
    ssh $ADMIN_USER@$server "sudo mkdir -p $SSH_KEY_PATH"
    
    # Set proper permissions
    ssh $ADMIN_USER@$server "sudo chown -R $DEV_USER:$DEV_USER $SSH_KEY_PATH"
    ssh $ADMIN_USER@$server "sudo chmod 700 $SSH_KEY_PATH"
    
    check_success "Remote user setup on $server"
}

# Function to distribute SSH public key
distribute_pub_key() {
    local server=$1
    log_message "Distributing SSH key to $server"
    
    # Copy public key and set permissions
    ssh $ADMIN_USER@$server "echo '$(sudo cat $SSH_KEY_PUB)' | sudo tee -a $SSH_KEY_PATH/authorized_keys &> /dev/null"
    ssh $ADMIN_USER@$server "sudo chown $DEV_USER:$DEV_USER $SSH_KEY_PATH/authorized_keys"
    ssh $ADMIN_USER@$server "sudo chmod 600 $SSH_KEY_PATH/authorized_keys"
    
    check_success "Key distribution to $server"
}

# Main execution
main() {
    log_message "Starting user setup and key distribution"
    
    # Create developer group
    create_dev_group
    
    # Create local user and generate keys
    create_local_users_and_keys $DEV_USER
    
    # Process remote hosts
    for server in "${REMOTE_HOSTS[@]}"; do
        create_dev_user_in_remote_hosts $server
        distribute_pub_key $server
    done
    
    log_message "Setup completed successfully"
}

# Execute main function
main