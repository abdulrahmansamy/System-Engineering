# Create users and Grant root permissions Script

```bash
#!/bin/bash
 
# List of remote servers
servers=("server1")  # Replace with actual server IPs or hostnames
 
# User details
new_user=""  # Replace with the desired username
user_password=""  # Replace with the desired password
 
# Function to create a user and grant root permissions on a remote server
create_user_and_grant_root() {
    local server="$1"
    ssh -t  "$server" "
        sudo useradd  $new_user &&
        echo '$new_user:$user_password' | sudo chpasswd &&
        sudo usermod -aG wheel $new_user &&
        echo '$new_user ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/$new_user &&
        sudo chmod 440 /etc/sudoers.d/$new_user
    "
}
 
# Loop through each server and execute the function
for server in "${servers[@]}"; do
    echo "Processing server: $server"
    create_user_and_grant_root "$server"
done
 
echo "User creation and root permission grant completed."
```