#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════
#  STEP 1: VPS Initial Setup & Hardening - Ubuntu 22.04
#
#  Purpose: Prepare a fresh Ubuntu VPS with security best practices
#  Run this FIRST before installing any services
#
#  Usage: sudo bash 01_server_setup.sh
#═══════════════════════════════════════════════════════════════════════════════

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║           VPS INITIAL SETUP - Ubuntu 22.04                        ║"
    echo "║           Server Hardening & Base Configuration                   ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_step() {
    echo -e "\n${GREEN}═══ $1 ═══${NC}"
}

log_info() {
    echo -e "${BLUE}➜${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

log_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

log_error() {
    echo -e "${RED}✗ $1${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root!"
        echo "Usage: sudo bash $0"
        exit 1
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 1: System Update & Upgrade
#═══════════════════════════════════════════════════════════════════════════════
update_system() {
    log_step "STEP 1: Updating System Packages"
    
    log_info "Updating package list..."
    apt update
    
    log_info "Upgrading installed packages..."
    DEBIAN_FRONTEND=noninteractive apt upgrade -y
    
    log_info "Performing full upgrade..."
    DEBIAN_FRONTEND=noninteractive apt full-upgrade -y
    
    log_info "Removing unused packages..."
    apt autoremove -y
    apt autoclean
    
    log_success "System updated successfully"
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 2: Install Essential Packages
#═══════════════════════════════════════════════════════════════════════════════
install_essentials() {
    log_step "STEP 2: Installing Essential Packages"
    
    PACKAGES=(
        # Security
        ufw fail2ban iptables ipset
        # System tools
        curl wget git unzip htop net-tools
        # Network tools
        netcat-openbsd tcpdump iproute2 dnsutils
        # Monitoring
        sysstat iotop
        # Compression
        zip unzip gzip
        # Text editors
        vim nano
        # Build tools (needed for some packages)
        build-essential software-properties-common
        # SSL/TLS
        ca-certificates
        # Process management
        supervisor
        # Time sync
        chrony
    )
    
    log_info "Installing ${#PACKAGES[@]} essential packages..."
    DEBIAN_FRONTEND=noninteractive apt install -y "${PACKAGES[@]}"
    
    log_success "Essential packages installed"
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 3: Configure Firewall (UFW)
#═══════════════════════════════════════════════════════════════════════════════
setup_firewall() {
    log_step "STEP 3: Configuring Firewall (UFW)"
    
    log_info "Setting up UFW firewall..."
    
    # Disable UFW first to apply clean rules
    ufw --force disable
    
    # Reset to defaults
    echo "y" | ufw reset
    
    # Default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    # Detect SSH Port
    SSH_PORT=$(grep "^Port " /etc/ssh/sshd_config | head -1 | awk '{print $2}')
    if [[ -z "$SSH_PORT" ]]; then
        SSH_PORT=22
        log_info "SSH runs on default port 22"
    else
        log_info "Detected custom SSH port: $SSH_PORT"
    fi
    
    # Allow SSH (IMPORTANT - don't lock yourself out!)
    ufw allow "$SSH_PORT"/tcp comment 'SSH'
    
    # Allow unprivileged ports (1024:65535) for Psiphon Conduit dynamic usage
    ufw allow 1024:65535/tcp comment 'Conduit Dynamic TCP'
    ufw allow 1024:65535/udp comment 'Conduit Dynamic UDP'
    
    # Enable UFW
    echo "y" | ufw enable
    
    log_success "Firewall configured"
    log_warn "Only SSH port $SSH_PORT is OPEN. Conduit ports will be added later."
    
    # Show status
    ufw status verbose
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 4: Configure Fail2Ban (Brute Force Protection)
#═══════════════════════════════════════════════════════════════════════════════
setup_fail2ban() {
    log_step "STEP 4: Configuring Fail2Ban"
    
    log_info "Setting up Fail2Ban for SSH protection..."
    
    # Create local configuration (overwrites if exists)
    cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
destemail = root@localhost
sendername = Fail2Ban
action = %(action_)s

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200
EOF
    
    # Restart fail2ban
    systemctl restart fail2ban
    systemctl enable fail2ban
    
    log_success "Fail2Ban configured and enabled"
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 5: Interactive SSH Hardening
#═══════════════════════════════════════════════════════════════════════════════
harden_ssh() {
    log_step "STEP 5: SSH Security Hardening"
    
    echo -e "${YELLOW}Would you like to enforce SSH Key Authentication and disable Password Login?${NC}"
    echo -e "${RED}WARNING: Make sure you have added your public key to ~root/.ssh/authorized_keys before saying YES!${NC}"
    read -p "Apply SSH hardening? (y/n): " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Backing up sshd_config..."
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
        
        log_info "Disabling password authentication..."
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
        sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
        
        # Verify config
        if sshd -t; then
            systemctl restart ssh
            log_success "SSH hardening applied. Password login disabled."
        else
            log_error "SSH config test failed! Reverting..."
            cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
            systemctl restart ssh
        fi
    else
        log_info "Skipping SSH hardening."
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 6: System Security Hardening
#═══════════════════════════════════════════════════════════════════════════════
harden_system() {
    log_step "STEP 6: System Security Hardening"
    
    # Secure shared memory (check idempotency)
    log_info "Securing shared memory..."
    if ! grep -q "tmpfs /run/shm" /etc/fstab; then
        echo "tmpfs /run/shm tmpfs defaults,noexec,nosuid 0 0" >> /etc/fstab
    fi
    
    # Set proper permissions on sensitive files
    log_info "Setting secure permissions..."
    chmod 644 /etc/passwd
    chmod 644 /etc/group
    chmod 600 /etc/shadow
    chmod 600 /etc/gshadow
    
    # Disable core dumps
    log_info "Disabling core dumps..."
    if ! grep -q "* hard core 0" /etc/security/limits.conf; then
        echo "* hard core 0" >> /etc/security/limits.conf
    fi
    
    # Network security settings
    log_info "Applying network security settings..."
    cat > /etc/sysctl.d/99-security.conf <<'EOF'
# IP Forwarding (enabled for Conduit)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.netfilter.nf_conntrack_max = 262144
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 1024
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
EOF
    
    # Apply sysctl settings
    sysctl -p /etc/sysctl.d/99-security.conf
    
    log_success "System hardening completed"
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 7: Time Synchronization
#═══════════════════════════════════════════════════════════════════════════════
setup_time_sync() {
    log_step "STEP 7: Configuring Time Synchronization"
    
    log_info "Setting timezone to UTC..."
    timedatectl set-timezone UTC
    
    log_info "Enabling chrony for time sync..."
    systemctl enable chrony
    systemctl restart chrony
    
    log_success "Time synchronization configured: $(date)"
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 8: Create Swap File (Recommended for 8GB RAM)
#═══════════════════════════════════════════════════════════════════════════════
create_swap() {
    log_step "STEP 8: Creating Swap File"
    
    # Check if swap already exists
    if swapon --show | grep -q swap; then
        log_warn "Swap already exists, skipping..."
        return
    fi
    
    log_info "Creating 4GB swap file..."
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    
    # Make swap permanent (idempotency check)
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    
    # Configure swappiness (idempotency check)
    if ! grep -q "vm.swappiness=10" /etc/sysctl.conf; then
        echo "vm.swappiness=10" >> /etc/sysctl.conf
        sysctl -p
    fi
    
    log_success "Swap file created and configured"
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 9: Setup Automatic Security Updates
#═══════════════════════════════════════════════════════════════════════════════
setup_auto_updates() {
    log_step "STEP 9: Configuring Automatic Security Updates"
    
    log_info "Installing unattended-upgrades..."
    apt install -y unattended-upgrades
    
    # Configure automatic updates for security patches only
    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    
    # Enable automatic updates
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
    
    log_success "Automatic security updates enabled"
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 10: Setup Monitoring Tools
#═══════════════════════════════════════════════════════════════════════════════
setup_monitoring() {
    log_step "STEP 10: Configuring System Monitoring"
    
    log_info "Creating monitoring aliases..."
    
    # Clean check before appending
    if ! grep -q "# System monitoring aliases" /root/.bashrc; then
        cat >> /root/.bashrc <<'EOF'

# System monitoring aliases
alias ports='netstat -tulanp'
alias meminfo='free -h'
alias cpuinfo='lscpu'
alias diskusage='df -h'
alias processlist='ps aux | grep -v grep'
alias connections='ss -s'
alias listening='ss -tulpn'
alias syslog='tail -f /var/log/syslog'
alias authlog='tail -f /var/log/auth.log'
alias stats='echo "=== CPU ==="; mpstat 1 1; echo "=== Memory ==="; free -h; echo "=== Disk ==="; df -h; echo "=== Network ==="; ss -s'
EOF
    fi
    
    log_success "Monitoring tools configured"
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 11: Summary & Next Steps
#═══════════════════════════════════════════════════════════════════════════════
show_summary() {
    log_step "SETUP COMPLETED SUCCESSFULLY!"
    
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                     SETUP SUMMARY                                 ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}✓${NC} System updated and upgraded"
    echo -e "${GREEN}✓${NC} Firewall (UFW) configured (SSH Port $SSH_PORT)"
    echo -e "${GREEN}✓${NC} Allowed ports 1024:65535 (Conduit Dynamic)"
    echo -e "${GREEN}✓${NC} Fail2Ban protection enabled"
    echo -e "${GREEN}✓${NC} System security hardened"
    echo -e "${GREEN}✓${NC} Swap file created (4GB)"
    echo -e "${GREEN}✓${NC} Automatic security updates enabled"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}NEXT STEPS:${NC}"
    echo ""
    echo "  1. Review firewall:"
    echo "     ${BLUE}sudo ufw status verbose${NC}"
    echo ""
    echo "  2. Run the conduit installer:"
    echo "     ${BLUE}sudo bash 02_install_conduit.sh${NC}"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    log_warn "If you changed SSH settings, do not disconnect until you verify you can login in a new session!"
    echo ""
}

#═══════════════════════════════════════════════════════════════════════════════
# Main Execution
#═══════════════════════════════════════════════════════════════════════════════
main() {
    print_header
    check_root
    
    echo -e "${YELLOW}This script will configure your server with security best practices.${NC}"
    echo -e "${YELLOW}It will update packages, configure firewall, and harden security.${NC}"
    echo ""
    read -p "Continue? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_error "Setup cancelled by user"
        exit 1
    fi
    
    # Execute setup steps
    update_system
    install_essentials
    setup_firewall
    setup_fail2ban
    harden_ssh
    harden_system
    setup_time_sync
    create_swap
    setup_auto_updates
    setup_monitoring
    
    # Show summary
    show_summary
}

# Run main function
main
