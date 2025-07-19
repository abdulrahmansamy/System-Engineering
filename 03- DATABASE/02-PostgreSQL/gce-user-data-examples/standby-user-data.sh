#!/bin/bash
# GCE User-data script for PostgreSQL HA Standby instance
# This script runs during instance startup

# Set up logging
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "$(date): Starting PostgreSQL HA Standby setup via user-data"

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

# Wait a bit for primary to start (if both instances start simultaneously)
echo "Waiting 120 seconds for primary instance to initialize..."
sleep 120

# Get IPs
PRIMARY_IP="10.0.1.10"  # Replace with actual primary IP or use instance discovery
STANDBY_IP=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip")

# Add metadata
gcloud compute instances add-metadata $(hostname) --metadata=primary-ip=$PRIMARY_IP,standby-ip=$STANDBY_IP

# Run the standby setup script
./02-pgsql_setup-standby.sh $PRIMARY_IP $STANDBY_IP

# Signal completion
echo "$(date): PostgreSQL HA Standby setup completed via user-data"
logger -t user-data "PostgreSQL HA Standby setup completed"
