#!/usr/bin/env bash

# Manual Cron Job Verification Script
# Purpose: Manually verify all cron jobs when automated scan fails
# Usage: sudo ./manual_cron_check.sh

set -euo pipefail

echo "=== Manual Cron Job Verification ==="
echo "Date: $(date)"
echo "User: $(whoami)"
echo

echo "=== 1. Checking cron service status ==="
systemctl status cron 2>/dev/null || systemctl status crond 2>/dev/null || echo "Cron service not found"
echo

echo "=== 2. Checking postgres user crontab ==="
echo "Running: sudo crontab -u postgres -l"
sudo crontab -u postgres -l 2>&1 || echo "No crontab for postgres user"
echo

echo "=== 3. Checking root crontab ==="
echo "Running: sudo crontab -l"
sudo crontab -l 2>&1 || echo "No crontab for root user"
echo

echo "=== 4. Checking /etc/cron.d/ ==="
if [[ -d /etc/cron.d ]]; then
    echo "Files in /etc/cron.d:"
    ls -la /etc/cron.d/ 2>/dev/null
    echo
    echo "Searching for PostgreSQL-related content:"
    grep -r "postgres\|pg_\|pgbouncer\|backup\|failover" /etc/cron.d/ 2>/dev/null || echo "No matches found"
else
    echo "/etc/cron.d not found"
fi
echo

echo "=== 5. Checking /etc/cron.daily/ ==="
if [[ -d /etc/cron.daily ]]; then
    ls -la /etc/cron.daily/ 2>/dev/null
    grep -r "postgres\|pg_\|pgbouncer" /etc/cron.daily/ 2>/dev/null || echo "No matches found"
else
    echo "/etc/cron.daily not found"
fi
echo

echo "=== 6. Checking /etc/cron.weekly/ ==="
if [[ -d /etc/cron.weekly ]]; then
    ls -la /etc/cron.weekly/ 2>/dev/null
    grep -r "postgres\|pg_\|pgbouncer" /etc/cron.weekly/ 2>/dev/null || echo "No matches found"
else
    echo "/etc/cron.weekly not found"
fi
echo

echo "=== 7. Checking systemd timers ==="
systemctl list-timers --all 2>/dev/null | head -20
echo
systemctl list-timers --all 2>/dev/null | grep -iE "postgres|pg_|backup|pgbouncer" || echo "No PostgreSQL-related timers found"
echo

echo "=== 8. Searching for backup scripts ==="
echo "Searching common locations for backup scripts..."
find /usr/local/bin /usr/local/sbin /opt /root /var/lib/postgresql -type f \( -name "*backup*" -o -name "*pg_*" \) 2>/dev/null | head -20
echo

echo "=== 9. Checking postgres user home directory ==="
POSTGRES_HOME=$(getent passwd postgres | cut -d: -f6)
echo "Postgres home: $POSTGRES_HOME"
if [[ -d "$POSTGRES_HOME" ]]; then
    find "$POSTGRES_HOME" -type f -name "*.sh" 2>/dev/null | head -10
else
    echo "Postgres home directory not accessible"
fi
echo

echo "=== 10. Checking at jobs ==="
atq 2>/dev/null || echo "No at jobs or at command not available"
echo

echo "=== Verification Complete ==="
