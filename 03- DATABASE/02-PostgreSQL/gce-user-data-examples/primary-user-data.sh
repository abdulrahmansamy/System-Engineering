#!/bin/bash
# GCE User-data script for PostgreSQL HA Primary instance
# This script runs during instance startup

# Set up logging
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "$(date): Starting PostgreSQL HA Primary setup via user-data"

# Update system
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y git curl

# Clone the PostgreSQL setup repository
cd /opt
git clone https://github.com/your-repo/postgresql-ha-setup.git
cd postgresql-ha-setup/02-HA_setup

# Make scripts executable
chmod +x *.sh

# Set instance metadata for IPs (customize these values)
STANDBY_IP="10.0.1.11"  # Replace with actual standby IP
PRIMARY_IP=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip")

# Add metadata for other scripts to discover
gcloud compute instances add-metadata $(hostname) --metadata=standby-ip=$STANDBY_IP,primary-ip=$PRIMARY_IP

# Run the primary setup script
./01-pgsql_setup-primary.sh $PRIMARY_IP $STANDBY_IP

# Signal completion
echo "$(date): PostgreSQL HA Primary setup completed via user-data"
logger -t user-data "PostgreSQL HA Primary setup completed"
