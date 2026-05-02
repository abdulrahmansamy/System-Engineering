#!/bin/bash
# repmgrd Service Fix Script
# Fixes the recursive startup issue and configuration problems

set -euo pipefail

echo "🔧 Fixing repmgrd service configuration issues..."

# 1. Stop any running repmgrd processes
echo "1. Stopping repmgrd services..."
sudo systemctl stop repmgrd.service || true
sudo pkill -f repmgrd || true

# 2. Remove the problematic service command configurations
echo "2. Fixing repmgr.conf - removing recursive service commands..."
sudo sed -i '/^repmgrd_service_start_command=/d' /etc/repmgr/repmgr.conf
sudo sed -i '/^repmgrd_service_stop_command=/d' /etc/repmgr/repmgr.conf

# 3. Create the correct systemd service file
echo "3. Creating corrected systemd service file..."
sudo tee /etc/systemd/system/repmgrd.service <<'EOF'
[Unit]
Description=PostgreSQL replication manager daemon
After=postgresql.service
Requires=postgresql.service
Wants=network-online.target
After=network-online.target

[Service]
Type=forking
User=postgres
Group=postgres
Environment=PGPASSFILE=/var/lib/postgresql/.pgpass
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/repmgr -f /etc/repmgr/repmgr.conf daemon start
ExecStop=/usr/bin/repmgr -f /etc/repmgr/repmgr.conf daemon stop
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10
TimeoutStartSec=30
TimeoutStopSec=30
KillMode=mixed
PIDFile=/var/run/repmgr/repmgrd.pid

[Install]
WantedBy=multi-user.target
EOF

# 4. Create PID directory
echo "4. Creating PID directory..."
sudo mkdir -p /var/run/repmgr
sudo chown postgres:postgres /var/run/repmgr

# 5. Update repmgr.conf with correct PID file location
echo "5. Adding PID file configuration to repmgr.conf..."
if ! grep -q "pid_file" /etc/repmgr/repmgr.conf; then
    echo "pid_file='/var/run/repmgr/repmgrd.pid'" | sudo tee -a /etc/repmgr/repmgr.conf
fi

# 6. Reload systemd and restart services
echo "6. Reloading systemd and starting services..."
sudo systemctl daemon-reload
sudo systemctl enable repmgrd.service

# 7. Start repmgrd manually first to test
echo "7. Testing repmgr daemon startup..."
sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf daemon start >/dev/null 2>&1 &
sleep 5

# Check if it's running
if sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf daemon status >/dev/null 2>&1; then
    echo "✅ repmgrd daemon started successfully!"
    # Stop it so systemd can manage it
    sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf daemon stop || true
    sleep 2
    
    # Start via systemd
    if sudo systemctl start repmgrd.service; then
        echo "✅ repmgrd systemd service started successfully!"
        sudo systemctl status repmgrd.service --no-pager || true
    else
        echo "❌ repmgrd systemd service failed to start"
    fi
else
    echo "❌ repmgrd daemon failed to start manually"
fi

echo ""
echo "🔍 Final status check:"
echo "  • repmgrd service: $(sudo systemctl is-active repmgrd.service 2>/dev/null || echo 'inactive')"
echo "  • repmgr cluster status:"
sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show 2>/dev/null || echo "    Cluster status unavailable"

echo ""
echo "✅ repmgrd fix script completed!"
echo "Run this script on BOTH nodes, then test failover again."