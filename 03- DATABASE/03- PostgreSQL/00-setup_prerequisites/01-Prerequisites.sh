#!/bin/bash
set -euo pipefail

# ─── Welcome Message ─────────────────────────────────────────────────────
echo -e "\n\033[1;36m==================== Welcome to PostgreSQL Prerequisites Setup ====================\033[0m"
echo -e "\033[1;36mThis script will configure prerequisites for your system for PostgreSQL deployment.\033[0m"
echo -e "\033[1;36m===================================================================================\033[0m\n"

# ─── Logging (trim unused levels for production) ─────────────────────────────────────────────────────
# Color codes
RED='\033[0;31m'       # Errors
GREEN='\033[0;32m'     # Success
YELLOW='\033[1;33m'    # Warnings
BLUE='\033[0;34m'      # Info
CYAN='\033[0;36m'      # Questions
MAGENTA='\033[0;35m'   # Debug
WHITE='\033[1;37m'     # Trace
GRAY='\033[0;37m'      # Silent
NC='\033[0m'           # No Color

# Timestamp
ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Logging functions
log()  { echo -e "${GREEN}[$(ts)] [+]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(ts)] [!]${NC} $*" >&2; }
die()  { echo -e "${RED}[$(ts)] [x]${NC} $*" >&2; exit 1; }
info() { echo -e "${BLUE}[$(ts)] [i]${NC} $*"; }
ask()  { echo -e "${CYAN}[$(ts)] [?]${NC} $*"; }
debug(){ echo -e "${MAGENTA}[$(ts)] [*]${NC} $*"; }
trace(){ echo -e "${WHITE}[$(ts)] [>]${NC} $*"; }
silent(){ echo -e "${GRAY}[$(ts)] [ ]${NC} $*"; }

# Info log (blue)
log_info() { local msg="$1"; echo -e "$(ts) ${BLUE}[INFO]${NC} $msg"; }

# Success log (green)
log_success() { local msg="$1"; echo -e "$(ts) ${GREEN}[SUCCESS]${NC} $msg"; }

VERBOSE=true
# Info log (blue)
log_info() { local msg="$1"; if [ "$VERBOSE" = true ]; then echo -e "$(ts) ${BLUE}[INFO]${NC} $msg"; fi; }

# Warning log (yellow)
log_warning() { local msg="$1"; if [ "$VERBOSE" = true ]; then echo -e "$(ts) ${YELLOW}[WARNING]${NC} $msg"; fi; }

# Success log (green)
log_success() { local msg="$1"; if [ "$VERBOSE" = true ]; then echo -e "$(ts) ${GREEN}[SUCCESS]${NC} $msg"; fi; }
# -------------------------------------------------------------
STARTTIME=$(date +"%Y%m%d-%H%M%S")
log_info "Script started. at $STARTTIME" | tee -a "pre-script-$STARTTIME.out.log" "pre-script-$STARTTIME.err.log"
# ─── System Information Gathering ─────────────────────────────────────────────

log_info "Checking CPU Info ..." | tee -a "pre-script-$STARTTIME.out.log"
lscpu >> "pre-script-$STARTTIME.out.log" 2>> "pre-script-$STARTTIME.err.log"

log_info "Checking Memory Info ..." | tee -a "pre-script-$STARTTIME.out.log"
free -h >> "pre-script-$STARTTIME.out.log" 2>> "pre-script-$STARTTIME.err.log"

log_info "Checking Disk Info ..." | tee -a "pre-script-$STARTTIME.out.log"
lsblk >> "pre-script-$STARTTIME.out.log" 2>> "pre-script-$STARTTIME.err.log"

log_info "Checking OS & Kernel Info ..." | tee -a "pre-script-$STARTTIME.out.log"
uname -a >> "pre-script-$STARTTIME.out.log" 2>> "pre-script-$STARTTIME.err.log"

log_info "Checking Distribution Info ..." | tee -a "pre-script-$STARTTIME.out.log"
lsb_release -a >> "pre-script-$STARTTIME.out.log" 2>> "pre-script-$STARTTIME.err.log"
cat /etc/os-release >> "pre-script-$STARTTIME.out.log" 2>> "pre-script-$STARTTIME.err.log"

# Update Kernel version
# Download the installer script
# log_info "Update Kernel Version"
# wget https://raw.githubusercontent.com/pimlie/ubuntu-mainline-kernel.sh/master/ubuntu-mainline-kernel.sh

# # Make it executable and move to PATH
# chmod +x ubuntu-mainline-kernel.sh
# sudo mv ubuntu-mainline-kernel.sh /usr/local/bin/

# # Check latest available kernel
# ubuntu-mainline-kernel.sh -c

# # Install a specific version (e.g. 6.12.10 or 6.16.3)
# # sudo ubuntu-mainline-kernel.sh -i v6.12.10
# # or
# sudo ubuntu-mainline-kernel.sh -i v6.16.3

# # Update GRUB
# sudo update-grub

# # Reboot to apply the new kernel
# log_warning "Rebooting to apply the new kernel..."
# sudo reboot

# # Check the current kernel version
# uname -r



# echo -e "\n=== Motherboard ==="
# sudo dmidecode -t baseboard

# echo -e "\n=== BIOS ==="
# sudo dmidecode -t bios


# Configure for current user
log_info "Configuring passwordless sudo for user $(id -un)..." | tee -a "pre-script-$STARTTIME.out.log" "pre-script-$STARTTIME.err.log"
echo "$(id -un) ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/$(id -un) >> "pre-script-$STARTTIME.out.log" 2>> "pre-script-$STARTTIME.err.log"
sudo chmod 0440 /etc/sudoers.d/$(id -un) >> "pre-script-$STARTTIME.out.log" 2>> "pre-script-$STARTTIME.err.log"
log_success "Sudoers configured for user $(id -un)." | tee -a "pre-script-$STARTTIME.out.log"

# Set timezone to Riyadh, KSA
log_info "Setting timezone to Asia/Riyadh..." | tee -a "pre-script-$STARTTIME.out.log" "pre-script-$STARTTIME.err.log"
sudo timedatectl set-timezone Asia/Riyadh >> "pre-script-$STARTTIME.out.log" 2>> "pre-script-$STARTTIME.err.log"

# Enable NTP synchronization
log_info "Enabling NTP sync..." | tee -a "pre-script-$STARTTIME.out.log" "pre-script-$STARTTIME.err.log"
sudo timedatectl set-ntp true >> "pre-script-$STARTTIME.out.log" 2>> "pre-script-$STARTTIME.err.log"

# Set timezone to Asia/Riyadh
log_info "Setting timezone to Asia/Riyadh..." | tee -a "pre-script-$STARTTIME.out.log" "pre-script-$STARTTIME.err.log"
sudo timedatectl set-timezone Asia/Riyadh >> "pre-script-$STARTTIME.out.log" 2>> "pre-script-$STARTTIME.err.log"
log_success "Timezone set to Riyadh (UTC+3)." | tee -a "pre-script-$STARTTIME.out.log"

log_info "Restarting systemd-timesyncd for fresh sync..." | tee -a "pre-script-$STARTTIME.out.log" "pre-script-$STARTTIME.err.log"
sudo systemctl restart systemd-timesyncd >> "pre-script-$STARTTIME.out.log" 2>> "pre-script-$STARTTIME.err.log"

log_success "NTP sync enabled and daemon restarted." | tee -a "pre-script-$STARTTIME.out.log"
sudo timedatectl status >> "pre-script-$STARTTIME.out.log" 2>> "pre-script-$STARTTIME.err.log"

log_info "Installing Vim package..." | tee -a "pre-script-$STARTTIME.out.log" "pre-script-$STARTTIME.err.log"
sudo apt install vim -y >> "pre-script-$STARTTIME.out.log" 2>> "pre-script-$STARTTIME.err.log"
log_success "Vim package installed successfully." | tee -a "pre-script-$STARTTIME.out.log"

log_info "Updating package lists..." | tee -a "pre-script-$STARTTIME.out.log" "pre-script-$STARTTIME.err.log"
sudo apt update -y >> "pre-script-$STARTTIME.out.log" 2>> "pre-script-$STARTTIME.err.log"
log_success "Package lists updated successfully." | tee -a "pre-script-$STARTTIME.out.log"
log_info "Upgrading installed packages..." | tee -a "pre-script-$STARTTIME.out.log" "pre-script-$STARTTIME.err.log"
sudo apt upgrade -y >> "pre-script-$STARTTIME.out.log" 2>> "pre-script-$STARTTIME.err.log"
log_success "Installed packages upgraded successfully." | tee -a "pre-script-$STARTTIME.out.log"

# ─── Set PostgreSQL Welcome Message for Machine Startup ───────────────────────
log_info "Setting PostgreSQL welcome message for machine startup..." | tee -a "pre-script-$STARTTIME.out.log" "pre-script-$STARTTIME.err.log"
sudo bash -c 'echo -e "\n\033[1;36m========== Welcome to PostgreSQL Primary instance - HA Setup =============\033[0m\n\033[1;36mThis system is configured for PostgreSQL Primary Instance - HA deployment.\033[0m\n\033[1;36m==========================================================================\033[0m\n" > /etc/motd'
log_success "PostgreSQL welcome message set for machine startup." | tee -a "pre-script-$STARTTIME.out.log"






