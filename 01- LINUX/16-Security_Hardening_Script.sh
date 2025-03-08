#!/bin/bash

# Exit on error, enable error trapping
set -e
trap 'echo "Error on line $LINENO"' ERR

# Configuration Variables
SSH_PORT=22222
DEV_GROUP="dev"
ALLOWED_COUNTRIES="US,CA"
LOG_SERVER="log-server:514"

# Function to log messages
log_message() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Function to detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        VERSION=$VERSION_ID
    else
        OS=$(uname -s)
        VERSION=$(uname -r)
    fi
    log_message "Detected OS: $OS $VERSION"
}

# Function to check command existence
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Basic security configurations for all systems
configure_basic_security() {
    log_message "Configuring basic security measures"

    # Create dev group
    sudo groupadd $DEV_GROUP 2>/dev/null || true

    # Disable root login
    sudo passwd -l root

    # Set directory permissions
    sudo chmod 750 /home/*
    sudo chmod 700 /etc/ssh

    # Configure sysctl security settings
    sudo tee /etc/sysctl.d/99-security.conf << EOF
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
EOF
    sudo sysctl -p /etc/sysctl.d/99-security.conf
}

# Configure SSH hardening
configure_ssh() {
    log_message "Hardening SSH configuration"

    # Backup SSH config
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

    # Generate new SSH keys
    sudo mv /etc/ssh/ssh_host_* /etc/ssh/backup/ 2>/dev/null || true
    sudo ssh-keygen -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N ""
    sudo ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ""
    sudo chmod 600 /etc/ssh/ssh_host_*

    # Configure SSH
    sudo tee /etc/ssh/sshd_config << EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
AllowGroups $DEV_GROUP
MaxAuthTries 3
MaxSessions 2
ClientAliveInterval 300
ClientAliveCountMax 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding yes
PermitTunnel no
EOF

    sudo systemctl restart sshd
}

# Configure RHEL/Fedora specific settings
configure_rhel() {
    log_message "Applying RHEL/Fedora specific configurations"

    # Install required packages
    sudo dnf install -y policycoreutils-python-utils setools-console aide \
        crypto-policies-scripts fapolicyd rkhunter firewalld fail2ban \
        setroubleshoot-server dnf-automatic

    # Configure SELinux
    sudo setenforce 1
    sudo sed -i 's/SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
    sudo semanage port -a -t ssh_port_t -p tcp $SSH_PORT || true

    # Configure firewalld
    sudo systemctl enable --now firewalld
    sudo firewall-cmd --permanent --remove-service=ssh
    sudo firewall-cmd --permanent --add-port=$SSH_PORT/tcp
    sudo firewall-cmd --reload

    # Configure automatic updates
    sudo sed -i 's/apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf
    sudo systemctl enable --now dnf-automatic.timer

    # Initialize AIDE
    sudo aide --init
    sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
}

# Configure Debian/Ubuntu specific settings
configure_debian() {
    log_message "Applying Debian/Ubuntu specific configurations"

    # Install required packages
    sudo apt update
    sudo apt install -y ufw fail2ban unattended-upgrades \
        xtables-addons-common xtables-addons-dkms rsyslog auditd

    # Configure UFW
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow $SSH_PORT/tcp
    sudo ufw --force enable

    # Configure automatic updates
    sudo dpkg-reconfigure -f noninteractive unattended-upgrades
}

# Configure logging and monitoring
configure_logging() {
    log_message "Setting up logging and monitoring"

    # Configure rsyslog
    sudo tee -a /etc/rsyslog.conf << EOF
*.* @@$LOG_SERVER
EOF
    sudo systemctl restart rsyslog

    # Configure audit rules
    sudo tee /etc/audit/rules.d/audit.rules << EOF
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/sudoers -p wa -k sudoers
-w /etc/passwd -p wa -k passwd
-w /etc/shadow -p wa -k shadow
EOF
    sudo service auditd restart
}

# Main execution
main() {
    log_message "Starting security hardening process"
    
    detect_os
    configure_basic_security
    configure_ssh

    case "$OS" in
        *"Red Hat"*|*"Fedora"*|*"CentOS"*)
            configure_rhel
            ;;
        *"Ubuntu"*|*"Debian"*)
            configure_debian
            ;;
        *)
            log_message "Unsupported OS: $OS"
            exit 1
            ;;
    esac

    configure_logging
    log_message "Security hardening completed successfully"
}

# Execute main function
main "$@"
