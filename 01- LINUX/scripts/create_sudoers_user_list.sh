#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

# Script to create user accounts and grant sudo access with password requirement
echo "Creating user accounts at $(date)"

# Create users with their emails
users=(
    "bob:bob@example.com"
    "charlie:charlie@example.com"
    "alice:alice@example.com"
)

for user_entry in "${users[@]}"; do
    username="${user_entry%%:*}"
    email="${user_entry##*:}"

    # Create user with home directory and email comment
    if id "${username}" &>/dev/null; then
        echo "User ${username} already exists."
    else
        useradd -m -c "${email}" "${username}"
        echo "${username}:Ch@ngeMe" | chpasswd
        chage -d 0 "${username}"
        echo "User ${username} created with comment: ${email}, and password set."
    fi

    # Grant sudo access (password required for sudo), idempotent
    sudoers_file="/etc/sudoers.d/${username}"
    if [[ -f "${sudoers_file}" ]]; then
        echo "Sudoers entry for ${username} already exists."
    else
        printf '%s ALL=(ALL) ALL\n' "${username}" > "${sudoers_file}"
        chmod 0440 "${sudoers_file}"
        echo "Sudo access with password required granted to ${username}."
    fi
done

echo "User accounts created and sudo access granted at $(date)"