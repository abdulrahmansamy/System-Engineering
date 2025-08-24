#!/bin/bash

# Install and configure Vault as a systemd service on a non-production environment

set -e

echo "Installing prerequisites..."
sudo dnf install -y dnf-plugins-core curl unzip firewalld

echo "Adding HashiCorp repository..."
sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/fedora/hashicorp.repo

echo "Installing Vault..."
sudo dnf install -y vault

echo "Creating Vault configuration..."
sudo mkdir -p /etc/vault.d
sudo tee /etc/vault.d/vault.hcl > /dev/null <<EOF
storage "file" {
  path = "/opt/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

ui = true
EOF

echo "Creating Vault data directory..."
sudo mkdir -p /opt/vault/data
sudo chown vault:vault /opt/vault/data

echo "Setting Vault environment variable..."
echo 'export VAULT_ADDR="http://127.0.0.1:8200"' | sudo tee /etc/profile.d/vault.sh
source /etc/profile.d/vault.sh

echo "Enabling and starting Vault service..."
sudo systemctl enable vault
sudo systemctl start vault

echo "Configuring firewall..."
sudo systemctl enable firewalld
sudo systemctl start firewalld
sudo firewall-cmd --permanent --add-port=8200/tcp
sudo firewall-cmd --permanent --add-service=ssh
sudo firewall-cmd --reload

echo "Vault installation complete. Version: $(vault version)"