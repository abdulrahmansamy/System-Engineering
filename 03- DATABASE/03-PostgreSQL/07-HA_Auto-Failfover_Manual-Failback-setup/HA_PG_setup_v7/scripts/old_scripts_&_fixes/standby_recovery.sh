#!/bin/bash
# Standby Node Recovery Script
# Run this ONLY on the standby node to complete the bootstrap

set -euo pipefail

info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

info "🔧 Standby Node Recovery"
info "========================"

# Check if we're on the standby node
if [[ "$(hostname -I | awk '{print $1}')" != "192.168.14.22" ]]; then
    error "This script should only be run on the standby node (192.168.14.22)"
    exit 1
fi

# Check if PostgreSQL is running
if ! systemctl is-active --quiet postgresql; then
    info "PostgreSQL is not running - completing standby setup..."
    
    # Check if primary is accessible
    if timeout 10 sudo -u postgres psql -h 192.168.14.21 -c "SELECT 1" >/dev/null 2>&1; then
        success "Primary node is accessible"
        
        # Stop any existing PostgreSQL processes
        systemctl stop postgresql 2>/dev/null || true
        sleep 2
        
        # Clean up existing data directory if needed
        if [[ -d /var/lib/postgresql/17/main ]] && [[ "$(ls -A /var/lib/postgresql/17/main 2>/dev/null)" ]]; then
            warn "Cleaning up existing data directory..."
            sudo -u postgres rm -rf /var/lib/postgresql/17/main/*
        fi
        
        # Clone from primary using repmgr
        info "Cloning from primary node..."
        if sudo -u postgres repmgr -h 192.168.14.21 -U repmgr -d repmgr standby clone --force; then
            success "Successfully cloned from primary"
            
            # Start PostgreSQL
            systemctl start postgresql
            sleep 5
            
            if systemctl is-active --quiet postgresql; then
                success "PostgreSQL started successfully"
                
                # Register with repmgr
                info "Registering standby with repmgr..."
                if sudo -u postgres repmgr standby register; then
                    success "Standby registered with repmgr"
                else
                    warn "Failed to register standby - may already be registered"
                fi
                
                # Start repmgrd
                systemctl enable repmgrd
                systemctl start repmgrd
                
                if systemctl is-active --quiet repmgrd; then
                    success "repmgrd started successfully"
                fi
                
                # Start PgBouncer
                systemctl start pgbouncer
                if systemctl is-active --quiet pgbouncer; then
                    success "PgBouncer started successfully"
                fi
                
                # Verify standby status
                if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" | grep -q "t"; then
                    success "Node is properly functioning as standby"
                else
                    error "Node is not in recovery mode - standby setup failed"
                fi
                
            else
                error "Failed to start PostgreSQL"
                exit 1
            fi
        else
            error "Failed to clone from primary"
            exit 1
        fi
    else
        error "Primary node is not accessible - cannot complete standby setup"
        exit 1
    fi
else
    success "PostgreSQL is already running"
fi

# Verify cluster status
info "Verifying cluster status..."
if sudo -u postgres repmgr cluster show >/dev/null 2>&1; then
    success "Cluster status accessible"
    sudo -u postgres repmgr cluster show
else
    warn "Cannot access cluster status"
fi

info ""
success "Standby node recovery completed!"
info "Next step: Run the quick health fix script to set up health endpoints"