# Security Hardening for Bastion Host

## 1. User Management and Access Control
### 1.1 Create Access Users
```bash
# Create developer group
sudo groupadd dev

# Create user and add to dev group
sudo useradd <username> -m -s /bin/bash
sudo usermod <username> -G dev

# Set secure password policy
sudo chage -M 90 -m 7 -W 7 <username>
```

### 1.2 Disable Root and Set Secure Permissions
```bash
# Disable root login
sudo passwd -l root

# Set secure permissions on critical directories
sudo chmod 750 /home/*
sudo chmod 700 /etc/ssh
```

## 2. Service and Port Hardening
### 2.1 Audit Running Services

#### Debian/Ubuntu
```bash
# List running services
systemctl list-units --type=service --state=running

# Disable unnecessary services
sudo systemctl disable --now <service_name>

# List open ports
ss -tulpn
lsof -i -P -n | grep LISTEN
```

#### RHEL/Fedora
```bash
# Install security tools
sudo dnf install policycoreutils-python-utils setools-console

# Check and configure SELinux
sestatus
getenforce
sudo setenforce 1
sudo sed -i 's/SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
```

### 2.2 Configure Firewall

#### Debian/Ubuntu
```bash
# Enable and configure UFW
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow <custom_ssh_port>/tcp
sudo ufw enable

# Install and configure fail2ban
sudo apt install fail2ban
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
```

#### RHEL/Fedora
```bash
# Configure firewalld
sudo dnf install firewalld
sudo systemctl enable --now firewalld

# Basic firewall rules
sudo firewall-cmd --permanent --remove-service=ssh
sudo firewall-cmd --permanent --add-port=22222/tcp
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.1.0/24" port port=22222 protocol=tcp accept'
sudo firewall-cmd --reload

# Install and configure fail2ban
sudo dnf install fail2ban
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
```

## 3. SSH Hardening
### 3.1 SSH Configuration
```bash
# Backup original config
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# Edit SSH configuration
sudo vim /etc/ssh/sshd_config
```

Essential sshd_config settings:
```ini
# Basic Security
Port 22222                           # Change default port
PermitRootLogin no                   # Disable root login
PasswordAuthentication no            # Disable password auth
PubkeyAuthentication yes             # Enable key-based auth
PermitEmptyPasswords no              # Prevent empty passwords

# Access Control
AllowGroups dev                      # Restrict SSH access to dev group
MaxAuthTries 3                       # Limit authentication attempts
MaxSessions 2                        # Limit concurrent sessions

# Timeout Settings
ClientAliveInterval 300              # 5 minutes timeout
ClientAliveCountMax 3                # Maximum 3 alive checks
LoginGraceTime 30                    # Login timeout

# Security Features
X11Forwarding no                     # Disable X11 forwarding
AllowAgentForwarding no             # Disable agent forwarding
AllowTcpForwarding yes              # Enable TCP forwarding
PermitTunnel no                      # Disable tunneling
```

### 3.2 Generate Strong Host Keys
```bash
# Backup existing keys
sudo cp /etc/ssh/ssh_host_* /etc/ssh/backup/

# Remove old keys
sudo rm /etc/ssh/ssh_host_*

# Generate new keys
sudo ssh-keygen -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N ""
sudo ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ""

# Set correct permissions
sudo chmod 600 /etc/ssh/ssh_host_*
```

## 4. System Hardening
### 4.1 System Configuration

#### Common Settings
```bash
# Update sysctl settings
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

# Apply changes
sudo sysctl -p /etc/sysctl.d/99-security.conf
```

#### RHEL/Fedora Specific
```bash
# Install security tools
sudo dnf install aide policycoreutils-python-utils audit crypto-policies-scripts fapolicyd rkhunter

# Configure AIDE
sudo aide --init
sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
echo '0 4 * * * root /usr/sbin/aide --check' | sudo tee /etc/cron.d/aide-check

# SELinux configuration
sudo semanage port -a -t ssh_port_t -p tcp 22222
sudo semanage boolean -m --on ssh_chroot_rw_homedirs

# Set crypto policies
sudo update-crypto-policies --set FUTURE
sudo systemctl enable --now fapolicyd
```

### 4.2 Automatic Updates

#### Debian/Ubuntu
```bash
sudo apt install unattended-upgrades
sudo dpkg-reconfigure unattended-upgrades
```

#### RHEL/Fedora
```bash
sudo dnf install dnf-automatic
sudo sed -i 's/apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf
sudo systemctl enable --now dnf-automatic.timer
```

## 5. Monitoring and Logging
### 5.1 Configure Centralized Logging
```bash
# Install rsyslog
sudo apt install rsyslog

# Configure remote logging
sudo tee -a /etc/rsyslog.conf << EOF
*.* @@log-server:514
EOF

# Restart rsyslog
sudo systemctl restart rsyslog
```

### 5.2 Setup Audit Rules
```bash
# Install auditd
sudo apt install auditd

# Configure basic audit rules
sudo tee /etc/audit/rules.d/audit.rules << EOF
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/sudoers -p wa -k sudoers
-w /etc/passwd -p wa -k passwd
-w /etc/shadow -p wa -k shadow
EOF

# Restart auditd
sudo service auditd restart
```

### 5.3 SELinux Audit Configuration
```bash
# Install SELinux tools
sudo dnf install setroubleshoot-server

# Configure SELinux audit rules
sudo auditctl -w /etc/selinux/config -p wa -k selinux_config
sudo auditctl -w /etc/selinux/targeted/contexts/files/file_contexts -p wa -k selinux_file_contexts

# Review SELinux denials
sudo ausearch -m AVC -ts recent
sudo sealert -a /var/log/audit/audit.log
```

## 6. Additional Security Measures
### 6.1 GeoIP Filtering
```bash
# Install required packages
sudo apt install xtables-addons-common xtables-addons-dkms

# Download and update GeoIP database
sudo wget -O /usr/share/xt_geoip/GeoIP.dat "URL_TO_GEOIP_DATABASE"

# Create GeoIP rules (example for allowing only US and CA)
sudo iptables -A INPUT -m geoip --src-cc US,CA -j ACCEPT
sudo iptables -A INPUT -j DROP
```

### 6.2 Regular Security Maintenance
- Monitor system logs daily: `sudo journalctl -xe`
- Check failed login attempts: `sudo tail -f /var/log/auth.log`
- Review active users: `w` and `who`
- Monitor system resources: `top` or `htop`
- Regular security audits with tools like Lynis

## 7. Verification Steps
1. Test SSH access with new configuration
2. Verify firewall rules: `sudo ufw status`
3. Check running services: `systemctl list-units --type=service`
4. Verify audit logs: `sudo ausearch -k sshd_config`
5. Test automatic updates: `sudo unattended-upgrades --dry-run`

## 8. RHEL/Fedora Specific Verification Steps
1. Verify SELinux status: `getenforce`
2. Check firewalld rules: `sudo firewall-cmd --list-all`
3. Verify crypto policies: `update-crypto-policies --show`
4. Check AIDE database: `sudo aide --check`
5. Review SELinux contexts: `ls -Z /etc/ssh/sshd_config`
6. Verify automatic updates: `systemctl status dnf-automatic.timer`
