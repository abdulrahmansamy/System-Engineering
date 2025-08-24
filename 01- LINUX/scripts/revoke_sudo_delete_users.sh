#!/bin/bash

# List of usernames to remove
usernames=("alice" "bob" "charlie")

for username in "${usernames[@]}"; do
    echo "Processing user: $username"

    # Remove sudoers file
    sudoers_file="/etc/sudoers.d/$username"
    if [ -f "$sudoers_file" ]; then
        rm -f "$sudoers_file"
        echo "Sudoers file removed for $username"
    else
        echo "No sudoers file found for $username"
    fi

    # Delete the user and their home directory
    if id "$username" &>/dev/null; then
        userdel -r "$username"
        echo "User $username deleted"
    else
        echo "User $username does not exist"
    fi

    echo "-----------------------------"
done