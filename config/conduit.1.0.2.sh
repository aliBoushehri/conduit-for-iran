#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║        🚀 PSIPHON CONDUIT MANAGER v1.0.2                          ║
# ║                                                                   ║
# ║  One-click setup for Psiphon Conduit                              ║
# ║                                                                   ║
# ║  • Installs Docker (if needed)                                    ║
# ║  • Runs Conduit in Docker with live stats                         ║
# ║  • Auto-start on boot via systemd/OpenRC/SysVinit                 ║
# ║  • Easy management via CLI or interactive menu                    ║
# ║                                                                   ║
# ║  GitHub: https://github.com/Psiphon-Inc/conduit                   ║
# ╚═══════════════════════════════════════════════════════════════════╝
# core engine: https://github.com/Psiphon-Labs/psiphon-tunnel-core
# Usage:
# curl -sL https://raw.githubusercontent.com/SamNet-dev/conduit-manager/main/conduit.sh | sudo bash
#
# Reference: https://github.com/ssmirr/conduit/releases/tag/d8522a8
# Conduit CLI options:
#   -m, --max-clients int   maximum number of proxy clients (1-1000) (default 200)
#   -b, --bandwidth float   bandwidth limit per peer in Mbps (1-40, or -1 for unlimited) (default 5)
#   -v, --verbose           increase verbosity (-v for verbose, -vv for debug)
#

set -e

# Ensure we're running in bash (not sh/dash)
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash. Please run with: bash $0"
    exit 1
fi

VERSION="1.0.2"
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:d8522a8"
INSTALL_DIR="${INSTALL_DIR:-/opt/conduit}"
BACKUP_DIR="$INSTALL_DIR/backups"
FORCE_REINSTALL=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

#═══════════════════════════════════════════════════════════════════════
# Utility Functions
#═══════════════════════════════════════════════════════════════════════

print_header() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                🚀 PSIPHON CONDUIT MANAGER v${VERSION}                  ║"
    echo "╠═══════════════════════════════════════════════════════════════════╣"
    echo "║  Help users access the open internet during shutdowns             ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

detect_os() {
    OS="unknown"
    OS_VERSION="unknown"
    OS_FAMILY="unknown"
    HAS_SYSTEMD=false
    PKG_MANAGER="unknown"
    
    # Detect OS from /etc/os-release
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
        OS_VERSION="${VERSION_ID:-unknown}"
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
    elif [ -f /etc/alpine-release ]; then
        OS="alpine"
    elif [ -f /etc/arch-release ]; then
        OS="arch"
    elif [ -f /etc/SuSE-release ] || [ -f /etc/SUSE-brand ]; then
        OS="opensuse"
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    fi
    
    # Determine OS family and package manager
    case "$OS" in
        ubuntu|debian|linuxmint|pop|elementary|zorin|kali|raspbian)
            OS_FAMILY="debian"
            PKG_MANAGER="apt"
            ;;
        rhel|centos|fedora|rocky|almalinux|oracle|amazon|amzn)
            OS_FAMILY="rhel"
            if command -v dnf &>/dev/null; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        arch|manjaro|endeavouros|garuda)
            OS_FAMILY="arch"
            PKG_MANAGER="pacman"
            ;;
        opensuse|opensuse-leap|opensuse-tumbleweed|sles)
            OS_FAMILY="suse"
            PKG_MANAGER="zypper"
            ;;
        alpine)
            OS_FAMILY="alpine"
            PKG_MANAGER="apk"
            ;;
        *)
            OS_FAMILY="unknown"
            PKG_MANAGER="unknown"
            ;;
    esac
    
    # Check for systemd
    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        HAS_SYSTEMD=true
    fi
    
    log_info "Detected: $OS ($OS_FAMILY family), Package manager: $PKG_MANAGER"

    if command -v podman &>/dev/null && ! command -v docker &>/dev/null; then
        log_warn "Podman detected. This script is optimized for Docker."
        log_warn "If installation fails, consider installing 'docker-ce' manually."
    fi
}

install_package() {
    local package="$1"
    log_info "Installing $package..."
    
    case "$PKG_MANAGER" in
        apt)
            # Make update failure non-fatal but log it
            apt-get update -q || log_warn "apt-get update failed, attempting to install regardless..."
            if apt-get install -y -q "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        dnf)
            if dnf install -y -q "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        yum)
            if yum install -y -q "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        pacman)
            if pacman -Sy --noconfirm "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        zypper)
            if zypper install -y -n "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        apk)
            if apk add --no-cache "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        *)
            log_warn "Unknown package manager. Please install $package manually."
            return 1
            ;;
    esac
}

check_dependencies() {
    # Check for bash
    if [ "$OS_FAMILY" = "alpine" ]; then
        if ! command -v bash &>/dev/null; then
            log_info "Installing bash (required for this script)..."
            apk add --no-cache bash 2>/dev/null
        fi
    fi
    
    # Check for curl
    if ! command -v curl &>/dev/null; then
        install_package curl || log_warn "Could not install curl automatically"
    fi
    
    # Check for basic tools
    if ! command -v awk &>/dev/null; then
        case "$PKG_MANAGER" in
            apt) install_package gawk || log_warn "Could not install gawk" ;;
            apk) install_package gawk || log_warn "Could not install gawk" ;;
            *) install_package awk || log_warn "Could not install awk" ;;
        esac
    fi
    
    # Check for free command
    if ! command -v free &>/dev/null; then
        case "$PKG_MANAGER" in
            apt|dnf|yum) install_package procps || log_warn "Could not install procps" ;;
            pacman) install_package procps-ng || log_warn "Could not install procps" ;;
            zypper) install_package procps || log_warn "Could not install procps" ;;
            apk) install_package procps || log_warn "Could not install procps" ;;
        esac
    fi

    # Check for tput (ncurses)
    if ! command -v tput &>/dev/null; then
        case "$PKG_MANAGER" in
            apt) install_package ncurses-bin || log_warn "Could not install ncurses-bin" ;;
            apk) install_package ncurses || log_warn "Could not install ncurses" ;;
            *) install_package ncurses || log_warn "Could not install ncurses" ;;
        esac
    fi

    # Check for tcpdump
    if ! command -v tcpdump &>/dev/null; then
        install_package tcpdump || log_warn "Could not install tcpdump automatically"
    fi

    # Check for GeoIP tools
    if ! command -v geoiplookup &>/dev/null; then
        case "$PKG_MANAGER" in
            apt) 
                # geoip-bin and geoip-database for newer systems
                install_package geoip-bin || log_warn "Could not install geoip-bin"
                install_package geoip-database || log_warn "Could not install geoip-database"
                ;;
            dnf|yum) 
                # On RHEL/CentOS
                if ! rpm -q epel-release &>/dev/null; then
                    log_info "Enabling EPEL repository for GeoIP..."
                    $PKG_MANAGER install -y epel-release &>/dev/null || true
                fi
                install_package GeoIP || log_warn "Could not install GeoIP."
                ;;
            pacman) install_package geoip || log_warn "Could not install geoip." ;;
            zypper) install_package GeoIP || log_warn "Could not install GeoIP." ;;
            apk) install_package geoip || log_warn "Could not install geoip." ;;
            *) log_warn "Could not install geoiplookup automatically" ;;
        esac
    fi
}

get_ram_mb() {
    # Get RAM in MB
    local ram=""
    
    # Try free command first
    if command -v free &>/dev/null; then
        ram=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    fi
    
    # Fallback: parse /proc/meminfo
    if [ -z "$ram" ] || [ "$ram" = "0" ]; then
        if [ -f /proc/meminfo ]; then
            local kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
            if [ -n "$kb" ]; then
                ram=$((kb / 1024))
            fi
        fi
    fi
    
    # Ensure minimum of 1
    if [ -z "$ram" ] || [ "$ram" -lt 1 ] 2>/dev/null; then
        echo 1
    else
        echo "$ram"
    fi
}

get_cpu_cores() {
    local cores=1
    if command -v nproc &>/dev/null; then
        cores=$(nproc)
    elif [ -f /proc/cpuinfo ]; then
        cores=$(grep -c ^processor /proc/cpuinfo)
    fi
    
    # Safety check
    if [ -z "$cores" ] || [ "$cores" -lt 1 ] 2>/dev/null; then
        echo 1
    else
        echo "$cores"
    fi
}

calculate_recommended_clients() {
    local cores=$(get_cpu_cores)
    # Logic: 100 clients per CPU core, max 1000
    local recommended=$((cores * 100))
    if [ "$recommended" -gt 1000 ]; then
        echo 1000
    else
        echo "$recommended"
    fi
}

#═══════════════════════════════════════════════════════════════════════
# Interactive Setup
#═══════════════════════════════════════════════════════════════════════

prompt_settings() {
    local ram_mb=$(get_ram_mb)
    local cpu_cores=$(get_cpu_cores)
    local recommended=$(calculate_recommended_clients)
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    CONDUIT CONFIGURATION                      ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Server Info:${NC}"
    echo -e "    CPU Cores: ${GREEN}${cpu_cores}${NC}"
    if [ "$ram_mb" -ge 1000 ]; then
        local ram_gb=$(awk "BEGIN {printf \"%.1f\", $ram_mb/1024}")
        echo -e "    RAM: ${GREEN}${ram_gb} GB${NC}"
    else
        echo -e "    RAM: ${GREEN}${ram_mb} MB${NC}"
    fi
    echo -e "    Recommended max-clients: ${GREEN}${recommended}${NC}"
    echo ""
    echo -e "  ${BOLD}Conduit Options:${NC}"
    echo -e "    ${YELLOW}--max-clients${NC}  Maximum proxy clients (1-1000)"
    echo -e "    ${YELLOW}--bandwidth${NC}    Bandwidth per peer in Mbps (1-40, or -1 for unlimited)"
    echo ""
    
    # Max clients prompt
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  Enter max-clients (1-1000)"
    echo -e "  Press Enter for recommended: ${GREEN}${recommended}${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    read -p "  max-clients: " input_clients < /dev/tty || true
    
    if [ -z "$input_clients" ]; then
        MAX_CLIENTS=$recommended
    elif [[ "$input_clients" =~ ^[0-9]+$ ]] && [ "$input_clients" -ge 1 ] && [ "$input_clients" -le 1000 ]; then
        MAX_CLIENTS=$input_clients
    else
        log_warn "Invalid input. Using recommended: $recommended"
        MAX_CLIENTS=$recommended
    fi
    
    echo ""
    
    # Bandwidth prompt
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  Do you want to set ${BOLD}UNLIMITED${NC} bandwidth? (Recommended for servers)"
    echo -e "  ${YELLOW}Note: High bandwidth usage may attract attention.${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    read -p "  Set unlimited bandwidth? [y/N] " unlimited_bw < /dev/tty || true

    if [[ "$unlimited_bw" =~ ^[Yy] ]]; then
        BANDWIDTH="-1"
        echo -e "  Selected: ${GREEN}Unlimited (-1)${NC}"
    else
        echo ""
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  Enter bandwidth per peer in Mbps (1-40)"
        echo -e "  Press Enter for default: ${GREEN}5${NC} Mbps"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        read -p "  bandwidth: " input_bandwidth < /dev/tty || true
        
        if [ -z "$input_bandwidth" ]; then
            BANDWIDTH=5
        elif [[ "$input_bandwidth" =~ ^[0-9]+$ ]] && [ "$input_bandwidth" -ge 1 ] && [ "$input_bandwidth" -le 40 ]; then
            BANDWIDTH=$input_bandwidth
        elif [[ "$input_bandwidth" =~ ^[0-9]*\.[0-9]+$ ]]; then
            local float_ok=$(awk -v val="$input_bandwidth" 'BEGIN { print (val >= 1 && val <= 40) ? "yes" : "no" }')
            if [ "$float_ok" = "yes" ]; then
                BANDWIDTH=$input_bandwidth
            else
                log_warn "Invalid input. Using default: 5 Mbps"
                BANDWIDTH=5
            fi
        else
            log_warn "Invalid input. Using default: 5 Mbps"
            BANDWIDTH=5
        fi
    fi
    
    echo ""
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Your Settings:${NC}"
    echo -e "    Max Clients: ${GREEN}${MAX_CLIENTS}${NC}"
    if [ "$BANDWIDTH" == "-1" ]; then
        echo -e "    Bandwidth:   ${GREEN}Unlimited${NC}"
    else
        echo -e "    Bandwidth:   ${GREEN}${BANDWIDTH}${NC} Mbps"
    fi
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo ""
    
    read -p "  Proceed with these settings? [Y/n] " confirm < /dev/tty || true
    if [[ "$confirm" =~ ^[Nn] ]]; then
        prompt_settings
    fi
}

#═══════════════════════════════════════════════════════════════════════
# Installation Functions
#═══════════════════════════════════════════════════════════════════════

install_docker() {
    if command -v docker &>/dev/null; then
        log_success "Docker is already installed"
        return 0
    fi
    
    log_info "Installing Docker..."
    
    # Check OS family for specific requirements
    if [ "$OS_FAMILY" = "rhel" ]; then
        log_info "Installing RHEL-specific Docker dependencies..."
        $PKG_MANAGER install -y -q dnf-plugins-core 2>/dev/null || true
        dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || true
    fi

    # Alpine
    if [ "$OS_FAMILY" = "alpine" ]; then
        apk add --no-cache docker docker-cli-compose 2>/dev/null
        rc-update add docker boot 2>/dev/null || true
        service docker start 2>/dev/null || rc-service docker start 2>/dev/null || true
    else
        # Use official Docker install
        if ! curl -fsSL https://get.docker.com | sh; then
            log_error "Official Docker installation script failed."
            log_info "Try installing docker manually: https://docs.docker.com/engine/install/"
            return 1
        fi
        
        # Enable and start Docker
        if [ "$HAS_SYSTEMD" = "true" ]; then
            systemctl enable docker 2>/dev/null || true
            systemctl start docker 2>/dev/null || true
        else
            # Fallback for non-systemd (SysVinit, OpenRC, etc.)
            if command -v update-rc.d &>/dev/null; then
                update-rc.d docker defaults 2>/dev/null || true
            elif command -v chkconfig &>/dev/null; then
                chkconfig docker on 2>/dev/null || true
            elif command -v rc-update &>/dev/null; then
                rc-update add docker default 2>/dev/null || true
            fi
            service docker start 2>/dev/null || /etc/init.d/docker start 2>/dev/null || true
        fi
    fi
    
    # Wait for Docker to be ready
    sleep 3
    local retries=27
    while ! docker info &>/dev/null && [ $retries -gt 0 ]; do
        sleep 1
        retries=$((retries - 1))
    done
    
    if docker info &>/dev/null; then
        log_success "Docker installed successfully"
    else
        log_error "Docker installation may have failed. Please check manually."
        return 1
    fi
}


#═══════════════════════════════════════════════════════════════════════
# check_and_offer_backup_restore() - Check for existing backup keys
#═══════════════════════════════════════════════════════════════════════
# Backup location: /opt/conduit/backups/
# Key file format: conduit_key_YYYYMMDD_HHMMSS.json
#
# Returns:
#   0 - Backup was restored (or none existed)
#   1 - User declined restore (fresh install)
#═══════════════════════════════════════════════════════════════════════
check_and_offer_backup_restore() {

    if [ ! -d "$BACKUP_DIR" ]; then
        return 0 
    fi

    # Find the most recent backup file
    local latest_backup=$(ls -t "$BACKUP_DIR"/conduit_key_*.json 2>/dev/null | head -1)

    if [ -z "$latest_backup" ]; then
        return 0 
    fi

    # Extract timestamp from filename for display
    local backup_filename=$(basename "$latest_backup")
    local backup_date=$(echo "$backup_filename" | sed -E 's/conduit_key_([0-9]{8})_([0-9]{6})\.json/\1/')
    local backup_time=$(echo "$backup_filename" | sed -E 's/conduit_key_([0-9]{8})_([0-9]{6})\.json/\2/')

    # Format date for display (YYYYMMDD -> YYYY-MM-DD)
    local formatted_date="${backup_date:0:4}-${backup_date:4:2}-${backup_date:6:2}"
    local formatted_time="${backup_time:0:2}:${backup_time:2:2}:${backup_time:4:2}"

    # Prompt user about restoring the backup
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  📁 PREVIOUS NODE IDENTITY BACKUP FOUND${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  A backup of your node identity key was found:"
    echo -e "    ${YELLOW}File:${NC} $backup_filename"
    echo -e "    ${YELLOW}Date:${NC} $formatted_date $formatted_time"
    echo ""
    echo -e "  Restoring this key will:"
    echo -e "    • Preserve your node's identity on the Psiphon network"
    echo -e "    • Maintain any accumulated reputation"
    echo -e "    • Allow peers to reconnect to your known node ID"
    echo ""
    echo -e "  ${YELLOW}Note:${NC} If you don't restore, a new identity will be generated."
    echo ""

    read -p "  Do you want to restore your previous node identity? (y/n): " restore_choice < /dev/tty || true

    if [ "$restore_choice" = "y" ] || [ "$restore_choice" = "Y" ]; then
        echo ""
        log_info "Restoring node identity from backup..."

        # Ensure the Docker volume exists
        docker volume create conduit-data 2>/dev/null || true
        docker run --rm -v conduit-data:/home/conduit/data -v "$BACKUP_DIR":/backup alpine \
            sh -c "cp /backup/$backup_filename /home/conduit/data/conduit_key.json && chown -R 1000:1000 /home/conduit/data"

        if [ $? -eq 0 ]; then
            log_success "Node identity restored successfully!"
            echo ""
            return 0
        else
            log_error "Failed to restore backup. Proceeding with fresh install."
            echo ""
            return 1
        fi
    else
        echo ""
        log_info "Skipping restore. A new node identity will be generated."
        echo ""
        return 1
    fi
}

# run_conduit() - Pull image, verify digest, and start container
run_conduit() {
    log_info "Starting Conduit container..."

    # Check for existing conduit containers (any image containing conduit)
    local existing=$(docker ps -a --filter "ancestor=ghcr.io/ssmirr/conduit/conduit" --format "{{.Names}}")
    if [ -n "$existing" ] && [ "$existing" != "conduit" ]; then
        log_warn "Detected other Conduit containers: $existing"
        log_warn "Running multiple instances may cause port conflicts."
    fi

    # Stop and remove any existing container
    docker rm -f conduit 2>/dev/null || true

    # Pull the official Conduit image from GitHub Container Registry
    log_info "Pulling Conduit image ($CONDUIT_IMAGE)..."
    if ! docker pull $CONDUIT_IMAGE; then
        log_error "Failed to pull Conduit image. Check your internet connection."
        exit 1
    fi


    # Ensure volume exists and has correct permissions for the conduit user (uid 1000)
    docker volume create conduit-data 2>/dev/null || true
    docker run --rm -v conduit-data:/home/conduit/data alpine \
        sh -c "chown -R 1000:1000 /home/conduit/data" 2>/dev/null || true

    # Start the Conduit container
    docker run -d \
        --name conduit \
        --restart unless-stopped \
        -v conduit-data:/home/conduit/data \
        --network host \
        $CONDUIT_IMAGE \
        start --max-clients "$MAX_CLIENTS" --bandwidth "$BANDWIDTH" --stats-file

    # Wait for container to initialize
    sleep 3

    # Verify container is running
    if docker ps | grep -q conduit; then
        log_success "Conduit container is running"
        if [ "$BANDWIDTH" == "-1" ]; then
            log_success "Settings: max-clients=$MAX_CLIENTS, bandwidth=Unlimited"
        else
            log_success "Settings: max-clients=$MAX_CLIENTS, bandwidth=${BANDWIDTH}Mbps"
        fi
    else
        log_error "Conduit failed to start"
        docker logs conduit 2>&1 | tail -10
        exit 1
    fi
}

save_settings() {
    mkdir -p "$INSTALL_DIR"
    
    # Save settings
    cat > "$INSTALL_DIR/settings.conf" << EOF
MAX_CLIENTS=$MAX_CLIENTS
BANDWIDTH=$BANDWIDTH
EOF
    
    if [ ! -f "$INSTALL_DIR/settings.conf" ]; then
        log_error "Failed to save settings. Check disk space and permissions."
        return 1
    fi
    
    log_success "Settings saved"
}

setup_autostart() {
    log_info "Setting up auto-start on boot..."
    
    if [ "$HAS_SYSTEMD" = "true" ]; then
        # Systemd-based systems
        local docker_path=$(command -v docker)
        cat > /etc/systemd/system/conduit.service << EOF
[Unit]
Description=Psiphon Conduit Service
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$docker_path start conduit
ExecStop=$docker_path stop conduit

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable conduit.service 2>/dev/null || true
        systemctl start conduit.service 2>/dev/null || true
        log_success "Systemd service created, enabled, and started"
        
    elif command -v rc-update &>/dev/null; then
        # OpenRC (Alpine, Gentoo, etc.)
        cat > /etc/init.d/conduit << 'EOF'
#!/sbin/openrc-run

name="conduit"
description="Psiphon Conduit Service"
depend() {
    need docker
    after network
}
start() {
    ebegin "Starting Conduit"
    docker start conduit
    eend $?
}
stop() {
    ebegin "Stopping Conduit"
    docker stop conduit
    eend $?
}
EOF
        chmod +x /etc/init.d/conduit
        rc-update add conduit default 2>/dev/null || true
        log_success "OpenRC service created and enabled"
        
    elif [ -d /etc/init.d ]; then
        # SysVinit fallback
        cat > /etc/init.d/conduit << 'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          conduit
# Required-Start:    $docker
# Required-Stop:     $docker
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Psiphon Conduit Service
### END INIT INFO

case "$1" in
    start)
        docker start conduit
        ;;
    stop)
        docker stop conduit
        ;;
    restart)
        docker restart conduit
        ;;
    status)
        docker ps | grep -q conduit && echo "Running" || echo "Stopped"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
EOF
        chmod +x /etc/init.d/conduit
        if command -v update-rc.d &>/dev/null; then
            update-rc.d conduit defaults 2>/dev/null || true
        elif command -v chkconfig &>/dev/null; then
            chkconfig conduit on 2>/dev/null || true
        fi
        log_success "SysVinit service created and enabled"
        
    else
        log_warn "Could not set up auto-start. Docker's restart policy will handle restarts."
        log_info "Container is set to restart unless-stopped, which works on reboot if Docker starts."
    fi
}

#═══════════════════════════════════════════════════════════════════════
# Management Script
#═══════════════════════════════════════════════════════════════════════

create_management_script() {
    # Generate the management script. 
    cat > "$INSTALL_DIR/conduit" << 'MANAGEMENT'
#!/bin/bash
#
# Psiphon Conduit Manager
# Reference: https://github.com/ssmirr/conduit/releases/tag/d8522a8
#

VERSION="1.0.2"
INSTALL_DIR="REPLACE_ME_INSTALL_DIR"
BACKUP_DIR="$INSTALL_DIR/backups"
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:d8522a8"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Load settings
[ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
MAX_CLIENTS=${MAX_CLIENTS:-200}
BANDWIDTH=${BANDWIDTH:-5}

# Ensure we're running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This command must be run as root (use sudo conduit)${NC}"
    exit 1
fi

# Check if Docker is available
check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}Error: Docker is not installed!${NC}"
        echo ""
        echo "Docker is required to run Conduit. Please reinstall:"
        echo "  curl -fsSL https://get.docker.com | sudo sh"
        echo ""
        echo "Or re-run the Conduit installer:"
        echo "  sudo bash conduit.sh"
        exit 1
    fi
    
    if ! docker info &>/dev/null; then
        echo -e "${RED}Error: Docker daemon is not running!${NC}"
        echo ""
        echo "Start Docker with:"
        echo "  sudo systemctl start docker       # For systemd"
        echo "  sudo /etc/init.d/docker start     # For SysVinit"
        echo "  sudo rc-service docker start      # For OpenRC"
        exit 1
    fi
}

# Run Docker check
check_docker

# Check for awk (needed for stats parsing)
if ! command -v awk &>/dev/null; then
    echo -e "${YELLOW}Warning: awk not found. Some stats may not display correctly.${NC}"
fi

# Helper: Fix volume permissions for conduit user (uid 1000)
fix_volume_permissions() {
    docker run --rm -v conduit-data:/home/conduit/data alpine \
        sh -c "chown -R 1000:1000 /home/conduit/data" 2>/dev/null || true
}

# Helper: Start/recreate conduit container with current settings
run_conduit_container() {
    docker run -d \
        --name conduit \
        --restart unless-stopped \
        -v conduit-data:/home/conduit/data \
        --network host \
        $CONDUIT_IMAGE \
        start --max-clients "$MAX_CLIENTS" --bandwidth "$BANDWIDTH" --stats-file
}

print_header() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    printf "║                🚀 PSIPHON CONDUIT MANAGER v%-5s                  ║\n" "${VERSION}"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_live_stats_header() {
    local EL="\033[K"
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${EL}"
    echo -e "║                    CONDUIT LIVE STATISTICS                        ║${EL}"
    echo -e "╠═══════════════════════════════════════════════════════════════════╣${EL}"
    printf "║  Max Clients: ${GREEN}%-52s${CYAN}║${EL}\n" "${MAX_CLIENTS}"
    if [ "$BANDWIDTH" == "-1" ]; then
        printf "║  Bandwidth:   ${GREEN}%-52s${CYAN}║${EL}\n" "Unlimited"
    else
        printf "║  Bandwidth:   ${GREEN}%-52s${CYAN}║${EL}\n" "${BANDWIDTH} Mbps"
    fi
    echo -e "║                                                                   ║${EL}"
    echo -e "╚═══════════════════════════════════════════════════════════════════╝${EL}"
    echo -e "${NC}\033[K"
}



get_node_id() {
    if docker volume inspect conduit-data >/dev/null 2>&1; then
        local mountpoint=$(docker volume inspect conduit-data --format '{{ .Mountpoint }}')
        if [ -f "$mountpoint/conduit_key.json" ]; then
            # Extract privateKeyBase64, decode, take last 32 bytes, encode base64
            # Logic provided by user
            cat "$mountpoint/conduit_key.json" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n'
        fi
    fi
}

show_dashboard() {
    local stop_dashboard=0
    # Setup trap to catch signals gracefully
    trap 'stop_dashboard=1' SIGINT SIGTERM
    
    # Use alternate screen buffer if available for smoother experience
    tput smcup 2>/dev/null || true
    echo -ne "\033[?25l" # Hide cursor
    # Initial clear
    clear

    while [ $stop_dashboard -eq 0 ]; do
        # Move cursor to top-left (0,0)
        # We NO LONGER clear the screen here to avoid the "full black" flash
        if ! tput cup 0 0 2>/dev/null; then
            printf "\033[H"
        fi
        
        print_live_stats_header
        
        show_status "live"
        
        # Show Node ID in its own section
        local node_id=$(get_node_id)
        if [ -n "$node_id" ]; then
            echo -e "${CYAN}═══ CONDUIT ID ═══${NC}\033[K"
            echo -e "  ${CYAN}${node_id}${NC}\033[K"
            echo -e "\033[K"
        fi

        echo -e "${BOLD}Refreshes every 5 seconds. Press any key to return to menu...${NC}\033[K"
        
        # Clear any leftover lines below the dashboard content (Erase to End of Display)
        # This only cleans up if the dashboard gets shorter
        if ! tput ed 2>/dev/null; then
            printf "\033[J"
        fi
        
        # Wait 4 seconds for keypress (compensating for processing time)
        # Redirect from /dev/tty ensures it works when the script is piped
        if read -t 4 -n 1 -s <> /dev/tty 2>/dev/null; then
            stop_dashboard=1
        fi
    done
    
    echo -ne "\033[?25h" # Show cursor
    # Restore main screen buffer
    tput rmcup 2>/dev/null || true
    trap - SIGINT SIGTERM # Reset traps
}

get_container_stats() {
    # Get CPU and RAM usage for conduit container
    # Returns: "CPU_PERCENT RAM_USAGE"
    local stats=$(docker stats --no-stream --format "{{.CPUPerc}} {{.MemUsage}}" conduit 2>/dev/null)
    if [ -z "$stats" ]; then
        echo "0% 0MiB"
    else
        # Extract just the raw numbers/units, simpler format
        echo "$stats"
    fi
}

get_cpu_cores() {
    local cores=1
    if command -v nproc &>/dev/null; then
        cores=$(nproc)
    elif [ -f /proc/cpuinfo ]; then
        cores=$(grep -c ^processor /proc/cpuinfo)
    fi
    if [ -z "$cores" ] || [ "$cores" -lt 1 ] 2>/dev/null; then echo 1; else echo "$cores"; fi
}

get_system_stats() {
    # Get System CPU (Live Delta) and RAM
    # Returns: "CPU_PERCENT RAM_USED RAM_TOTAL RAM_PCT"
    
    # 1. System CPU (Stateful Average)
    local sys_cpu="0%"
    local cpu_tmp="/tmp/conduit_cpu_state"
    
    if [ -f /proc/stat ]; then
        read -r cpu user nice system idle iowait irq softirq steal guest < /proc/stat
        local total_curr=$((user + nice + system + idle + iowait + irq + softirq + steal))
        local work_curr=$((user + nice + system + irq + softirq + steal))
        
        if [ -f "$cpu_tmp" ]; then
            read -r total_prev work_prev < "$cpu_tmp"
            local total_delta=$((total_curr - total_prev))
            local work_delta=$((work_curr - work_prev))
            
            if [ "$total_delta" -gt 0 ]; then
                local cpu_usage=$(awk -v w="$work_delta" -v t="$total_delta" 'BEGIN { printf "%.1f", w * 100 / t }' 2>/dev/null || echo 0)
                sys_cpu="${cpu_usage}%"
            fi
        else
            sys_cpu="Calc..." # First run calibration
        fi
        
        # Save current state for next run
        echo "$total_curr $work_curr" > "$cpu_tmp"
    else
        sys_cpu="N/A"
    fi
    
    # 2. System RAM (Used, Total, Percentage)
    local sys_ram_used="N/A"
    local sys_ram_total="N/A"
    local sys_ram_pct="N/A"
    
    if command -v free &>/dev/null; then
        # Output: used total percentage
        local ram_data=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%s %s %.2f%%", $3, $2, ($3/$2)*100}')
        local ram_human=$(free -h 2>/dev/null | awk '/^Mem:/{print $3 " " $2}')
        
        sys_ram_used=$(echo "$ram_human" | awk '{print $1}')
        sys_ram_total=$(echo "$ram_human" | awk '{print $2}')
        sys_ram_pct=$(echo "$ram_data" | awk '{print $3}')
    fi
    
    echo "$sys_cpu $sys_ram_used $sys_ram_total $sys_ram_pct"
}

show_live_stats() {
    # Check if container is running first
    if ! docker ps 2>/dev/null | grep -q "[[:space:]]conduit$"; then
        print_header
        echo -e "${RED}Conduit is not running!${NC}"
        echo "Start it first with option 6 or 'conduit start'"
        read -n 1 -s -r -p "Press any key to continue..." < /dev/tty 2>/dev/null || true
        return 1
    fi

    echo -e "${CYAN}Streaming live statistics... Press Ctrl+C to return to menu${NC}"
    echo -e "${YELLOW}(showing live logs filtered for [STATS])${NC}"
    echo ""

    # Trap Ctrl+C to allow handled exit from the log stream
    trap 'echo -e "\n${CYAN}Returning to menu...${NC}"; return' SIGINT

    # Stream logs and filter for [STATS]
    # We check if grep supports --line-buffered for smoother output, fallback to standard grep
    if grep --help 2>&1 | grep -q -- --line-buffered; then
        docker logs -f --tail 20 conduit 2>&1 | grep --line-buffered "\[STATS\]"
    else
        docker logs -f --tail 20 conduit 2>&1 | grep "\[STATS\]"
    fi

    # Reset trap
    trap - SIGINT
}

# format_bytes() - Convert bytes to human-readable format (B, KB, MB, GB)
format_bytes() {
    local bytes=$1

    # Handle empty or zero input
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ] 2>/dev/null; then
        echo "0 B"
        return
    fi

    # Convert based on size thresholds (using binary units)
    # 1 GB = 1073741824 bytes (1024^3)
    # 1 MB = 1048576 bytes (1024^2)
    # 1 KB = 1024 bytes
    if [ "$bytes" -ge 1073741824 ]; then
        awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
    elif [ "$bytes" -ge 1048576 ]; then
        awk "BEGIN {printf \"%.2f MB\", $bytes/1048576}"
    elif [ "$bytes" -ge 1024 ]; then
        awk "BEGIN {printf \"%.2f KB\", $bytes/1024}"
    else
        echo "$bytes B"
    fi
}

# show_peers() - Live peer traffic by country using tcpdump + GeoIP
show_peers() {
    # Flag to control the main loop - set to 1 on user interrupt
    local stop_peers=0
    trap 'stop_peers=1' SIGINT SIGTERM

    # Verify required dependencies are installed
    if ! command -v tcpdump &>/dev/null || ! command -v geoiplookup &>/dev/null; then
        echo -e "${RED}Error: tcpdump or geoiplookup not found!${NC}"
        echo "Please re-run the main installer to fix dependencies."
        read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
        return 1
    fi

    # Network interface detection
    # Use "any" to capture on all interfaces
    local iface="any"

    # Detect local IP address to determine traffic direction
    # Method 1: Query the route to a public IP (most reliable)
    # Method 2: Fallback to hostname -I
    local local_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')
    [ -z "$local_ip" ] && local_ip=$(hostname -I | awk '{print $1}')

    # Clean temporary working files (per-cycle data only)
    rm -f /tmp/conduit_peers_current /tmp/conduit_peers_raw
    rm -f /tmp/conduit_traffic_from /tmp/conduit_traffic_to
    touch /tmp/conduit_traffic_from /tmp/conduit_traffic_to

    # Persistent data directory - survives across option 9 sessions
    local persist_dir="/opt/conduit/traffic_stats"
    mkdir -p "$persist_dir"

    # Get container start time to detect restarts
    local container_start=$(docker inspect --format='{{.State.StartedAt}}' conduit 2>/dev/null | cut -d'.' -f1)
    local stored_start=""
    [ -f "$persist_dir/container_start" ] && stored_start=$(cat "$persist_dir/container_start")

    # If container was restarted, reset all cumulative data
    if [ "$container_start" != "$stored_start" ]; then
        echo "$container_start" > "$persist_dir/container_start"
        rm -f "$persist_dir/cumulative_data" "$persist_dir/cumulative_ips" "$persist_dir/session_start"
    fi

    # Cumulative data files persist until Conduit restarts
    # Format: Country|TotalFrom|TotalTo (bytes received from / sent to)
    [ ! -f "$persist_dir/cumulative_data" ] && touch "$persist_dir/cumulative_data"
    # Format: Country|IP (one line per unique IP seen)
    [ ! -f "$persist_dir/cumulative_ips" ] && touch "$persist_dir/cumulative_ips"

    # Session start time - when we first started tracking (persists until Conduit restart)
    if [ ! -f "$persist_dir/session_start" ]; then
        date +%s > "$persist_dir/session_start"
    fi
    local session_start=$(cat "$persist_dir/session_start")

    # Enter alternate screen buffer (preserves terminal history)
    tput smcup 2>/dev/null || true
    # Hide cursor for cleaner display
    echo -ne "\033[?25l"

    #═══════════════════════════════════════════════════════════════════
    # Main display loop - runs until user presses a key
    #═══════════════════════════════════════════════════════════════════
    while [ $stop_peers -eq 0 ]; do
        # Clear screen completely and move to top-left
        clear
        printf "\033[H"

        #───────────────────────────────────────────────────────────────
        # Header Section - Compact title bar with live status indicator
        # Shows: Title, session duration, and [LIVE - last 15s] indicator
        #───────────────────────────────────────────────────────────────
        # Calculate how long this view session has been running
        local now=$(date +%s)
        local duration=$((now - session_start))
        local dur_min=$((duration / 60))
        local dur_sec=$((duration % 60))
        local duration_str=$(printf "%02d:%02d" $dur_min $dur_sec)

        echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "║                    LIVE PEER TRAFFIC BY COUNTRY                   ║"
        echo -e "${CYAN}╠═══════════════════════════════════════════════════════════════════╣${NC}"
        if [ -f /tmp/conduit_peers_current ]; then
            # Data is available - show last update time
            local update_time=$(date '+%H:%M:%S')
            echo -e "║  Last Update: ${update_time}                                    ${GREEN}[LIVE]${NC}  ║"
        else
            # Waiting for first data capture
            echo -e "║  Status: ${YELLOW}Initializing...${NC}                                         ║"
        fi
        echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
        echo -e ""

        #───────────────────────────────────────────────────────────────
        # Data Tables - Display TOP 10 countries by traffic volume
        #
        # "TRAFFIC FROM" = Data received from that country (incoming)
        #                  These are peers connecting TO your Conduit node
        # "TRAFFIC TO"   = Data sent to that country (outgoing)
        #                  This is data your node sends back to peers
        #
        # Columns explained:
        #   Total    = Cumulative bytes since this view started
        #   Speed    = Current transfer rate (from last 15-second window)
        #   IPs      = Unique IP addresses (Total seen / Currently active)
        #
        # Colors: GREEN = incoming traffic, YELLOW = outgoing traffic
        #         #FreeIran = RED (solidarity highlight)
        #───────────────────────────────────────────────────────────────
        if [ -s /tmp/conduit_traffic_from ]; then
            # Section 1: Top 10 countries by incoming traffic (data FROM them)
            # This shows which countries have peers connecting to your node
            echo -e "${GREEN}${BOLD}   📥 TOP 10 TRAFFIC FROM (peers connecting to you)${NC}"
            echo -e "   ─────────────────────────────────────────────────────────────────────────"
            printf "   ${BOLD}%-26s${NC}  ${GREEN}${BOLD}%10s   %12s${NC}   %-12s\n" "Country" "Total" "Speed" "IPs (all/now)"
            echo -e "   ─────────────────────────────────────────────────────────────────────────"
            # Read top 10 entries from incoming-traffic-sorted file
            head -10 /tmp/conduit_traffic_from | while read -r line; do
                # Parse pipe-delimited fields: Country|TotalFrom|TotalTo|SpeedFrom|SpeedTo|TotalIPs|ActiveIPs
                local country=$(echo "$line" | cut -d'|' -f1)
                local from_bytes=$(echo "$line" | cut -d'|' -f2)
                local from_speed=$(echo "$line" | cut -d'|' -f4)
                local total_ips=$(echo "$line" | cut -d'|' -f6)
                local active_ips=$(echo "$line" | cut -d'|' -f7)
                # Format bytes to human-readable (KB/MB/GB)
                local from_fmt=$(format_bytes "$from_bytes")
                local from_spd_fmt=$(format_bytes "$from_speed")/s
                # Format IP counts - handle empty values
                [ -z "$total_ips" ] && total_ips="0"
                [ -z "$active_ips" ] && active_ips="0"
                local ip_display="${total_ips}/${active_ips}"
                # Print row: CYAN country, GREEN values (Total/Speed right-aligned, IPs left-aligned)
                printf "   ${CYAN}%-26s${NC}  ${GREEN}${BOLD}%10s   %12s${NC}   %-12s\n" "$country" "$from_fmt" "$from_spd_fmt" "$ip_display"
            done
            echo ""

            # Section 2: Top 10 countries by outgoing traffic (data TO them)
            # This shows which countries you're sending the most data to
            echo -e "${YELLOW}${BOLD}   📤 TOP 10 TRAFFIC TO (data sent to peers)${NC}"
            echo -e "   ─────────────────────────────────────────────────────────────────────────"
            printf "   ${BOLD}%-26s${NC}  ${YELLOW}${BOLD}%10s   %12s${NC}   %-12s\n" "Country" "Total" "Speed" "IPs (all/now)"
            echo -e "   ─────────────────────────────────────────────────────────────────────────"
            # Read top 10 entries from outgoing-traffic-sorted file
            head -10 /tmp/conduit_traffic_to | while read -r line; do
                # Parse pipe-delimited fields: Country|TotalFrom|TotalTo|SpeedFrom|SpeedTo|TotalIPs|ActiveIPs
                local country=$(echo "$line" | cut -d'|' -f1)
                local to_bytes=$(echo "$line" | cut -d'|' -f3)
                local to_speed=$(echo "$line" | cut -d'|' -f5)
                local total_ips=$(echo "$line" | cut -d'|' -f6)
                local active_ips=$(echo "$line" | cut -d'|' -f7)
                # Format bytes to human-readable (KB/MB/GB)
                local to_fmt=$(format_bytes "$to_bytes")
                local to_spd_fmt=$(format_bytes "$to_speed")/s
                # Format IP counts - handle empty values
                [ -z "$total_ips" ] && total_ips="0"
                [ -z "$active_ips" ] && active_ips="0"
                local ip_display="${total_ips}/${active_ips}"
                # Print row: CYAN country, YELLOW values (Total/Speed right-aligned, IPs left-aligned)
                printf "   ${CYAN}%-26s${NC}  ${YELLOW}${BOLD}%10s   %12s${NC}   %-12s\n" "$country" "$to_fmt" "$to_spd_fmt" "$ip_display"
            done
        else
            # No data yet - show waiting message with padding
            echo -e "   ${YELLOW}Waiting for first snapshot... (High traffic helps speed this up)${NC}"
            for i in {1..20}; do echo ""; done
        fi

        echo -e ""
        echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"

        #═══════════════════════════════════════════════════════════════════
        # Background Traffic Capture
        #═══════════════════════════════════════════════════════════════════
        # Uses tcpdump to capture live network packets for 15 seconds
        # tcpdump flags:
        #   -n  : Don't resolve hostnames (faster)
        #   -i  : Interface to capture on ("any" = all interfaces)
        #   -q  : Quiet output (less verbose)
        #
        # The captured output is piped to awk which:
        #   1. Extracts source and destination IP addresses
        #   2. Extracts packet length from each line
        #   3. Filters out private/local IP ranges (RFC 1918)
        #   4. Determines traffic direction (from vs to)
        #   5. Aggregates bytes per IP address
        #   6. Outputs: IP|bytes_from_remote|bytes_to_remote
        #
        # Traffic direction naming (from your server's perspective):
        #   "from" = bytes received FROM remote IP (remote -> local)
        #   "to"   = bytes sent TO remote IP (local -> remote)
        #═══════════════════════════════════════════════════════════════════
        # Wrap pipeline in subshell so $! captures the whole pipeline PID, not just awk
        # This ensures the progress indicator runs for the full 15-second capture
        (
            timeout 15 tcpdump -ni $iface -q '(tcp or udp)' 2>/dev/null | \
            awk -v local_ip="$local_ip" '
            # Portable awk script - works with mawk, gawk, and busybox awk
            /IP/ {
                # Parse tcpdump output to extract IPs and packet length
                # Example format: "IP 192.168.1.1.443 > 8.8.8.8.12345: TCP, length 1460"
                # Or: "IP 10.0.0.1.22 > 203.0.113.5.54321: UDP, length 64"

                src = ""
                dst = ""
                len = 0

                # Find the field containing "IP" and extract source/dest
                for (i = 1; i <= NF; i++) {
                    if ($i == "IP") {
                        # Next field is source IP.port
                        src_field = $(i+1)
                        # Field after ">" is dest IP.port
                        for (j = i+2; j <= NF; j++) {
                            if ($(j-1) == ">") {
                                dst_field = $j
                                # Remove trailing colon if present
                                gsub(/:$/, "", dst_field)
                                break
                            }
                        }
                        break
                    }
                }

                # Extract IP from IP.port format (remove last .port segment)
                # Example: 192.168.1.1.443 -> 192.168.1.1
                if (src_field != "") {
                    n = split(src_field, parts, ".")
                    if (n >= 4) {
                        src = parts[1] "." parts[2] "." parts[3] "." parts[4]
                    }
                }
                if (dst_field != "") {
                    n = split(dst_field, parts, ".")
                    if (n >= 4) {
                        dst = parts[1] "." parts[2] "." parts[3] "." parts[4]
                    }
                }

                # Extract packet length - look for "length N" pattern
                for (i = 1; i <= NF; i++) {
                    if ($i == "length") {
                        len = $(i+1) + 0
                        break
                    }
                }
                # Fallback: use last numeric field if no "length" found
                if (len == 0) {
                    for (i = NF; i > 0; i--) {
                        if ($i ~ /^[0-9]+$/) {
                            len = $i + 0
                            break
                        }
                    }
                }

                # Skip if we could not parse IPs
                if (src == "" && dst == "") next

                # Filter out private/reserved IP ranges (RFC 1918 + others)
                # 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8,
                # 0.0.0.0/8, 169.254.0.0/16 (link-local)
                if (src ~ /^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|0\.|169\.254\.)/) src = ""
                if (dst ~ /^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|0\.|169\.254\.)/) dst = ""

                # Determine traffic direction based on local IP
                # "traffic_from" = bytes coming FROM remote (incoming to your server)
                # "traffic_to"   = bytes going TO remote (outgoing from your server)
                if (src == local_ip && dst != "" && dst != local_ip) {
                    # Outgoing: packet going FROM local TO remote
                    traffic_to[dst] += len
                    ips[dst] = 1
                } else if (dst == local_ip && src != "" && src != local_ip) {
                    # Incoming: packet coming FROM remote TO local
                    traffic_from[src] += len
                    ips[src] = 1
                } else if (src != "" && src != local_ip) {
                    # Fallback: non-local source = incoming traffic
                    traffic_from[src] += len
                    ips[src] = 1
                } else if (dst != "" && dst != local_ip) {
                    # Fallback: non-local destination = outgoing traffic
                    traffic_to[dst] += len
                    ips[dst] = 1
                }
            }
            END {
                # Output aggregated data: IP|bytes_from|bytes_to
                for (ip in ips) {
                    from_bytes = traffic_from[ip] + 0  # Default to 0 if undefined
                    to_bytes = traffic_to[ip] + 0
                    print ip "|" from_bytes "|" to_bytes
                }
            }' > /tmp/conduit_peers_raw
        ) 2>/dev/null &

        # Store subshell PID for cleanup if user exits early
        local tcpdump_pid=$!

        #───────────────────────────────────────────────────────────────
        # Progress Indicator Loop - runs for exactly 15 seconds
        # Shows animated dots while tcpdump captures data
        # Checks for user keypress every second to allow early exit
        #───────────────────────────────────────────────────────────────
        local count=0
        while [ $count -lt 15 ]; do
            if read -t 1 -n 1 -s <> /dev/tty 2>/dev/null; then
                stop_peers=1
                kill $tcpdump_pid 2>/dev/null
                break
            fi
            count=$((count + 1))
            echo -ne "\r  [${YELLOW}"
            for ((i=0; i<count; i++)); do echo -n "•"; done
            for ((i=count; i<15; i++)); do echo -n " "; done
            echo -ne "${NC}] Capturing next update... (Any key to exit) \033[K"
        done

        # Wait for tcpdump to finish (should already be done after 15s)
        wait $tcpdump_pid 2>/dev/null

        # Exit loop if user requested stop
        if [ $stop_peers -eq 1 ]; then break; fi

        #═══════════════════════════════════════════════════════════════════
        # GeoIP Resolution and Country Aggregation (Cumulative)
        #═══════════════════════════════════════════════════════════════════
        # Process the raw IP data:
        #   1. Read each IP with its from/to bytes from this cycle
        #   2. Resolve IP to country using geoiplookup
        #   3. Add to cumulative totals (persisted in temp file)
        #   4. Track unique IPs per country (cumulative and active)
        #   5. Calculate bandwidth speed (bytes per second from 15s window)
        #   6. Create sorted output files for display
        #
        # Traffic direction naming:
        #   "from" = bytes received FROM remote IP (incoming to your server)
        #   "to"   = bytes sent TO remote IP (outgoing from your server)
        #═══════════════════════════════════════════════════════════════════
        if [ -s /tmp/conduit_peers_raw ]; then
            # Associative arrays for this capture cycle - MUST unset first!
            # In bash, 'declare -A' does NOT clear existing arrays, causing accumulation bug
            unset cycle_from cycle_to cycle_ips ip_to_country
            declare -A cycle_from       # Bytes received FROM each country this cycle
            declare -A cycle_to         # Bytes sent TO each country this cycle
            declare -A cycle_ips        # IPs seen this cycle per country (for active count)
            declare -A ip_to_country    # Map IP -> country for deduplication

            # Process each IP from the raw capture data
            # Raw format: IP|bytes_from|bytes_to
            while IFS='|' read -r ip from_bytes to_bytes; do
                [ -z "$ip" ] && continue

                # Resolve IP to country using GeoIP database
                local country_info=$(geoiplookup "$ip" 2>/dev/null | awk -F: '/Country Edition/{print $2}' | sed 's/^ //')
                [ -z "$country_info" ] && country_info="Unknown"

                # Normalize certain country names for display
                country_info=$(echo "$country_info" | sed 's/Iran, Islamic Republic of/Iran - #FreeIran/' | sed 's/Moldova, Republic of/Moldova/')

                # Store IP to country mapping for later
                ip_to_country["$ip"]="$country_info"

                # Aggregate this cycle's traffic by country
                cycle_from["$country_info"]=$((${cycle_from["$country_info"]:-0} + from_bytes))
                cycle_to["$country_info"]=$((${cycle_to["$country_info"]:-0} + to_bytes))

                # Track active IPs this cycle (append IP to country's IP list)
                cycle_ips["$country_info"]="${cycle_ips["$country_info"]} $ip"
            done < /tmp/conduit_peers_raw

            # Load existing cumulative traffic data from persistent storage
            unset cumul_from cumul_to
            declare -A cumul_from
            declare -A cumul_to
            if [ -s "$persist_dir/cumulative_data" ]; then
                while IFS='|' read -r country cfrom cto; do
                    [ -z "$country" ] && continue
                    cumul_from["$country"]=$cfrom
                    cumul_to["$country"]=$cto
                done < "$persist_dir/cumulative_data"
            fi

            # Add this cycle's traffic to cumulative totals
            for country in "${!cycle_from[@]}"; do
                cumul_from["$country"]=$((${cumul_from["$country"]:-0} + ${cycle_from["$country"]}))
                cumul_to["$country"]=$((${cumul_to["$country"]:-0} + ${cycle_to["$country"]}))
            done

            # Save updated cumulative traffic data to persistent storage
            > "$persist_dir/cumulative_data"
            for country in "${!cumul_from[@]}"; do
                echo "${country}|${cumul_from[$country]}|${cumul_to[$country]}" >> "$persist_dir/cumulative_data"
            done

            # Update cumulative IP tracking (add new IPs seen this cycle)
            for ip in "${!ip_to_country[@]}"; do
                local country="${ip_to_country[$ip]}"
                # Check if this IP|Country combo already exists
                if ! grep -q "^${country}|${ip}$" "$persist_dir/cumulative_ips" 2>/dev/null; then
                    echo "${country}|${ip}" >> "$persist_dir/cumulative_ips"
                fi
            done

            # Count total unique IPs per country (cumulative)
            unset total_ips_count
            declare -A total_ips_count
            if [ -s "$persist_dir/cumulative_ips" ]; then
                while IFS='|' read -r country ip; do
                    [ -z "$country" ] && continue
                    total_ips_count["$country"]=$((${total_ips_count["$country"]:-0} + 1))
                done < "$persist_dir/cumulative_ips"
            fi

            # Count active IPs this cycle per country
            unset active_ips_count
            declare -A active_ips_count
            for country in "${!cycle_ips[@]}"; do
                # Count unique IPs in this cycle's IP list for this country
                local unique_count=$(echo "${cycle_ips[$country]}" | tr ' ' '\n' | sort -u | grep -c '.')
                active_ips_count["$country"]=$unique_count
            done

            # Generate sorted output with all metrics
            # Format: Country|TotalFrom|TotalTo|SpeedFrom|SpeedTo|TotalIPs|ActiveIPs
            > /tmp/conduit_traffic_from
            > /tmp/conduit_traffic_to
            for country in "${!cumul_from[@]}"; do
                local total_from=${cumul_from[$country]}
                local total_to=${cumul_to[$country]}
                local cycle_from_val=${cycle_from["$country"]:-0}
                local cycle_to_val=${cycle_to["$country"]:-0}
                # Calculate speed (bytes per second) from 15-second capture
                local speed_from=$((cycle_from_val / 15))
                local speed_to=$((cycle_to_val / 15))
                # Get IP counts
                local total_ips=${total_ips_count["$country"]:-0}
                local active_ips=${active_ips_count["$country"]:-0}
                echo "${country}|${total_from}|${total_to}|${speed_from}|${speed_to}|${total_ips}|${active_ips}" >> /tmp/conduit_traffic_from
            done

            # Sort by total incoming traffic (field 2) descending
            sort -t'|' -k2 -nr -o /tmp/conduit_traffic_from /tmp/conduit_traffic_from

            # Copy and sort by total outgoing traffic (field 3) descending
            cp /tmp/conduit_traffic_from /tmp/conduit_traffic_to
            sort -t'|' -k3 -nr -o /tmp/conduit_traffic_to /tmp/conduit_traffic_to

            # Touch marker file to indicate data is ready for display
            touch /tmp/conduit_peers_current
        fi

        echo -ne "\r  ${GREEN}✓ Update complete! Refreshing...${NC} \033[K"
        sleep 1
    done
    # End of main display loop

    #═══════════════════════════════════════════════════════════════════
    # Cleanup - restore terminal state and remove temp files
    # Note: Persistent data in /opt/conduit/traffic_stats/ is NOT removed
    #       It persists until Conduit container restarts
    #═══════════════════════════════════════════════════════════════════
    echo -ne "\033[?25h"  # Show cursor
    tput rmcup 2>/dev/null || true  # Exit alternate screen buffer
    # Remove only temporary working files (not persistent cumulative data)
    rm -f /tmp/conduit_peers_current /tmp/conduit_peers_raw
    rm -f /tmp/conduit_traffic_from /tmp/conduit_traffic_to
    trap - SIGINT SIGTERM  # Remove signal handlers
}

get_net_speed() {
    # Calculate System Network Speed (Active 0.5s Sample)
    # Returns: "RX_MBPS TX_MBPS"
    local iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5}')
    [ -z "$iface" ] && iface=$(ip route list default 2>/dev/null | awk '{print $5}')
    
    if [ -n "$iface" ] && [ -f "/sys/class/net/$iface/statistics/rx_bytes" ]; then
        local rx1=$(cat /sys/class/net/$iface/statistics/rx_bytes)
        local tx1=$(cat /sys/class/net/$iface/statistics/tx_bytes)
        
        sleep 0.5
        
        local rx2=$(cat /sys/class/net/$iface/statistics/rx_bytes)
        local tx2=$(cat /sys/class/net/$iface/statistics/tx_bytes)
        
        # Calculate Delta (Bytes)
        local rx_delta=$((rx2 - rx1))
        local tx_delta=$((tx2 - tx1))
        
        # Convert to Mbps: (bytes * 8 bits) / (0.5 sec * 1,000,000)
        # Formula simplified: bytes * 16 / 1000000
        
        local rx_mbps=$(awk -v b="$rx_delta" 'BEGIN { printf "%.2f", (b * 16) / 1000000 }')
        local tx_mbps=$(awk -v b="$tx_delta" 'BEGIN { printf "%.2f", (b * 16) / 1000000 }')
        
        echo "$rx_mbps $tx_mbps"
    else
        echo "0.00 0.00"
    fi
}

show_status() {
    local mode="${1:-normal}" # 'live' mode adds line clearing
    local EL=""
    if [ "$mode" == "live" ]; then
        EL="\033[K" # Erase Line escape code
    fi

    echo ""

    
    if docker ps 2>/dev/null | grep -q "[[:space:]]conduit$"; then
        # Fetch stats once
        local logs=$(docker logs --tail 1000 conduit 2>&1 | grep "STATS" | tail -1)
        
        # Get Resource Stats
        local stats=$(get_container_stats)
        
        # Normalize App CPU (Docker % / Cores)
        local raw_app_cpu=$(echo "$stats" | awk '{print $1}' | tr -d '%')
        local num_cores=$(get_cpu_cores)
        local app_cpu="0%"
        local app_cpu_display=""
        
        if [[ "$raw_app_cpu" =~ ^[0-9.]+$ ]]; then
             # Use awk for floating point math
             app_cpu=$(awk -v cpu="$raw_app_cpu" -v cores="$num_cores" 'BEGIN {printf "%.2f%%", cpu / cores}')
             if [ "$num_cores" -gt 1 ]; then
                 app_cpu_display="${app_cpu} (${raw_app_cpu}% vCPU)"
             else
                 app_cpu_display="${app_cpu}"
             fi
        else
             app_cpu="${raw_app_cpu}%"
             app_cpu_display="${app_cpu}"
        fi
        
        # Keep full "Used / Limit" string for App RAM
        local app_ram=$(echo "$stats" | awk '{print $2, $3, $4}') 
        
        local sys_stats=$(get_system_stats)
        local sys_cpu=$(echo "$sys_stats" | awk '{print $1}')
        local sys_ram_used=$(echo "$sys_stats" | awk '{print $2}')
        local sys_ram_total=$(echo "$sys_stats" | awk '{print $3}')
        local sys_ram_pct=$(echo "$sys_stats" | awk '{print $4}')
        
        local sys_ram_pct=$(echo "$sys_stats" | awk '{print $4}')
        
        # New Metric: Network Speed (System Wide)
        local net_speed=$(get_net_speed)
        local rx_mbps=$(echo "$net_speed" | awk '{print $1}')
        local tx_mbps=$(echo "$net_speed" | awk '{print $2}')
        local net_display="↓ ${rx_mbps} Mbps  ↑ ${tx_mbps} Mbps"
        
        if [ -n "$logs" ]; then
            local connecting=$(echo "$logs" | sed -n 's/.*Connecting:[[:space:]]*\([0-9]*\).*/\1/p')
            local connected=$(echo "$logs" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p')
            local upload=$(echo "$logs" | sed -n 's/.*Up:[[:space:]]*\([^|]*\).*/\1/p' | xargs)
            local download=$(echo "$logs" | sed -n 's/.*Down:[[:space:]]*\([^|]*\).*/\1/p' | xargs)
            local uptime=$(echo "$logs" | sed -n 's/.*Uptime:[[:space:]]*\(.*\)/\1/p' | xargs)
            
            # Default to 0 if missing/empty
            connecting=${connecting:-0}
            connected=${connected:-0}
            
            echo -e "🚀 PSIPHON CONDUIT MANAGER v${VERSION}${EL}"
            echo -e "${NC}${EL}"
            
            if [ -n "$uptime" ]; then
                 echo -e "${BOLD}Status:${NC} ${GREEN}Running${NC} (${uptime})  |  ${BOLD}Clients:${NC} ${GREEN}${connected}${NC} connected, ${YELLOW}${connecting}${NC} connecting${EL}"
            else
                 echo -e "${BOLD}Status:${NC} ${GREEN}Running${NC}  |  ${BOLD}Clients:${NC} ${GREEN}${connected}${NC} connected, ${YELLOW}${connecting}${NC} connecting${EL}"
            fi
            
            echo -e "${EL}"
            echo -e "${CYAN}═══ Traffic ═══${NC}${EL}"
            [ -n "$upload" ] && echo -e "  Upload:       ${CYAN}${upload}${NC}${EL}"
            [ -n "$download" ] && echo -e "  Download:     ${CYAN}${download}${NC}${EL}"
            
            echo -e "${EL}"
            echo -e "${CYAN}═══ Resource Usage ═══${NC}${EL}"
            printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "App:" "$app_cpu_display" "$app_ram"
            printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "System:" "$sys_cpu" "$sys_ram_used / $sys_ram_total"
            printf "  %-8s Net: ${YELLOW}%-43s${NC}${EL}\n" "Total:" "$net_display"
            
        else
             echo -e "🚀 PSIPHON CONDUIT MANAGER v${VERSION}${EL}"
             echo -e "${NC}${EL}"
             echo -e "${BOLD}Status:${NC} ${GREEN}Running${NC}${EL}"
             echo -e "${EL}"
             echo -e "${CYAN}═══ Resource Usage ═══${NC}${EL}"
             printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "App:" "$app_cpu_display" "$app_ram"
             printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "System:" "$sys_cpu" "$sys_ram_used / $sys_ram_total"
             printf "  %-8s Net: ${YELLOW}%-43s${NC}${EL}\n" "Total:" "$net_display"
             echo -e "${EL}"
             echo -e "  Stats:        ${YELLOW}Waiting for first stats...${NC}${EL}"
        fi
        
    else
        echo -e "🚀 PSIPHON CONDUIT MANAGER v${VERSION}${EL}"
        echo -e "${NC}${EL}"
        echo -e "${BOLD}Status:${NC} ${RED}Stopped${NC}${EL}"
    fi
    

    
    echo ""
    echo -e "${CYAN}═══ SETTINGS ═══${NC}${EL}"
    echo -e "  Max Clients:  ${MAX_CLIENTS}${EL}"
    if [ "$BANDWIDTH" == "-1" ]; then
        echo -e "  Bandwidth:    Unlimited${EL}"
    else
        echo -e "  Bandwidth:    ${BANDWIDTH} Mbps${EL}"
    fi

    
    echo ""
    echo -e "${CYAN}═══ AUTO-START SERVICE ═══${NC}"
    # Check for systemd
    if command -v systemctl &>/dev/null && systemctl is-enabled conduit.service 2>/dev/null | grep -q "enabled"; then
        echo -e "  Auto-start:   ${GREEN}Enabled (systemd)${NC}"
        local svc_status=$(systemctl is-active conduit.service 2>/dev/null)
        echo -e "  Service:      ${svc_status:-unknown}"
    # Check for OpenRC
    elif command -v rc-status &>/dev/null && rc-status -a 2>/dev/null | grep -q "conduit"; then
        echo -e "  Auto-start:   ${GREEN}Enabled (OpenRC)${NC}"
    # Check for SysVinit
    elif [ -f /etc/init.d/conduit ]; then
        echo -e "  Auto-start:   ${GREEN}Enabled (SysVinit)${NC}"
    else
        echo -e "  Auto-start:   ${YELLOW}Not configured${NC}"
        echo -e "  Note:         Docker restart policy handles restarts"
    fi
    echo ""
}

start_conduit() {
    echo "Starting Conduit..."

    # Check if container exists (running or stopped)
    if docker ps -a 2>/dev/null | grep -q "[[:space:]]conduit$"; then
        # Check if container is already running
        if docker ps 2>/dev/null | grep -q "[[:space:]]conduit$"; then
            echo -e "${GREEN}✓ Conduit is already running${NC}"
            return 0
        fi

        # Container exists but stopped - recreate it to ensure -v flag is included
        echo "Recreating container with stats enabled..."
        docker rm conduit 2>/dev/null || true
    fi

    # Create new container
    echo "Creating Conduit container..."
    docker volume create conduit-data 2>/dev/null || true

    fix_volume_permissions
    run_conduit_container

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Conduit started with stats enabled${NC}"
    else
        echo -e "${RED}✗ Failed to start Conduit${NC}"
        return 1
    fi
}

stop_conduit() {
    echo "Stopping Conduit..."
    if docker ps 2>/dev/null | grep -q "[[:space:]]conduit$"; then
        docker stop conduit 2>/dev/null
        echo -e "${YELLOW}✓ Conduit stopped${NC}"
    else
        echo -e "${YELLOW}Conduit is not running${NC}"
    fi
}

restart_conduit() {
    echo "Restarting Conduit..."
    if docker ps -a 2>/dev/null | grep -q "[[:space:]]conduit$"; then
        # Stop and remove the existing container
        docker stop conduit 2>/dev/null || true
        docker rm conduit 2>/dev/null || true

        fix_volume_permissions
        run_conduit_container

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Conduit restarted with stats enabled${NC}"
        else
            echo -e "${RED}✗ Failed to restart Conduit${NC}"
            return 1
        fi
    else
        echo -e "${RED}Conduit container not found. Use 'conduit start' to create it.${NC}"
        return 1
    fi
}

change_settings() {
    echo ""
    echo -e "${CYAN}Current Settings:${NC}"
    echo -e "  Max Clients: ${MAX_CLIENTS}"
    if [ "$BANDWIDTH" == "-1" ]; then
        echo -e "  Bandwidth:   Unlimited"
    else
        echo -e "  Bandwidth:   ${BANDWIDTH} Mbps"
    fi
    echo ""
    
    read -p "New max-clients (1-1000) [${MAX_CLIENTS}]: " new_clients < /dev/tty || true

    
    # Bandwidth prompt logic for settings menu
    echo ""
    if [ "$BANDWIDTH" == "-1" ]; then
        echo "Current bandwidth: Unlimited"
    else
        echo "Current bandwidth: ${BANDWIDTH} Mbps"
    fi
    read -p "Set unlimited bandwidth (-1)? [y/N]: " set_unlimited < /dev/tty || true
    
    if [[ "$set_unlimited" =~ ^[Yy] ]]; then
        new_bandwidth="-1"
    else
        read -p "New bandwidth in Mbps (1-40) [${BANDWIDTH}]: " input_bw < /dev/tty || true
        if [ -n "$input_bw" ]; then
            new_bandwidth="$input_bw"
        fi
    fi
    
    # Validate max-clients
    if [ -n "$new_clients" ]; then
        if [[ "$new_clients" =~ ^[0-9]+$ ]] && [ "$new_clients" -ge 1 ] && [ "$new_clients" -le 1000 ]; then
            MAX_CLIENTS=$new_clients
        else
            echo -e "${YELLOW}Invalid max-clients. Keeping current: ${MAX_CLIENTS}${NC}"
        fi
    fi
    
    # Validate bandwidth
    if [ -n "$new_bandwidth" ]; then
        if [ "$new_bandwidth" = "-1" ]; then
             BANDWIDTH="-1"
        elif [[ "$new_bandwidth" =~ ^[0-9]+$ ]] && [ "$new_bandwidth" -ge 1 ] && [ "$new_bandwidth" -le 40 ]; then
            BANDWIDTH=$new_bandwidth
        elif [[ "$new_bandwidth" =~ ^[0-9]*\.[0-9]+$ ]]; then
            local float_ok=$(awk -v val="$new_bandwidth" 'BEGIN { print (val >= 1 && val <= 40) ? "yes" : "no" }')
            if [ "$float_ok" = "yes" ]; then
                BANDWIDTH=$new_bandwidth
            else
                echo -e "${YELLOW}Invalid bandwidth. Keeping current: ${BANDWIDTH}${NC}"
            fi
        else
            echo -e "${YELLOW}Invalid bandwidth. Keeping current: ${BANDWIDTH}${NC}"
        fi
    fi
    
    # Save settings
    cat > "$INSTALL_DIR/settings.conf" << EOF
MAX_CLIENTS=$MAX_CLIENTS
BANDWIDTH=$BANDWIDTH
EOF

    echo ""
    echo "Updating and recreating Conduit container with new settings..."
    docker rm -f conduit 2>/dev/null || true
    sleep 2  # Wait for container cleanup to complete
    echo "Pulling latest image..."
    docker pull $CONDUIT_IMAGE 2>/dev/null || echo -e "${YELLOW}Could not pull latest image, using cached version${NC}"
    fix_volume_permissions
    run_conduit_container

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Settings updated and Conduit restarted${NC}"
        echo -e "  Max Clients: ${MAX_CLIENTS}"
        if [ "$BANDWIDTH" == "-1" ]; then
            echo -e "  Bandwidth:   Unlimited"
        else
            echo -e "  Bandwidth:   ${BANDWIDTH} Mbps"
        fi
    else
        echo -e "${RED}✗ Failed to restart Conduit${NC}"
    fi
}

#═══════════════════════════════════════════════════════════════════════
# show_logs() - Display color-coded Docker logs
#═══════════════════════════════════════════════════════════════════════
# Colors log entries based on their type:
#   [OK]     - Green   (successful operations)
#   [INFO]   - Cyan    (informational messages)
#   [STATS]  - Blue    (statistics)
#   [WARN]   - Yellow  (warnings)
#   [ERROR]  - Red     (errors)
#   [DEBUG]  - Gray    (debug messages)
#═══════════════════════════════════════════════════════════════════════
show_logs() {
    if ! docker ps -a 2>/dev/null | grep -q conduit; then
        echo -e "${RED}Conduit container not found.${NC}"
        return 1
    fi

    echo -e "${CYAN}Streaming all logs (filtered, no [STATS])... Press Ctrl+C to stop${NC}"
    echo ""

    # Stream ALL docker logs, filtering out [STATS] lines for cleaner output
    docker logs -f conduit 2>&1 | grep -v "\[STATS\]"
}

uninstall_all() {
    echo ""
    echo -e "${RED}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                    ⚠️  UNINSTALL CONDUIT                          ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "This will completely remove:"
    echo "  • Conduit Docker container"
    echo "  • Conduit Docker image"
    echo "  • Conduit data volume (all stored data)"
    echo "  • Auto-start service (systemd/OpenRC/SysVinit)"
    echo "  • Configuration files"
    echo "  • Management CLI"
    echo ""
    echo -e "${RED}WARNING: This action cannot be undone!${NC}"
    echo ""
    read -p "Are you sure you want to uninstall? (type 'yes' to confirm): " confirm < /dev/tty || true

    if [ "$confirm" != "yes" ]; then
        echo "Uninstall cancelled."
        return 0
    fi

    # Check for backup keys
    local keep_backups=false
    if [ -d "$BACKUP_DIR" ] && [ "$(ls -A $BACKUP_DIR 2>/dev/null)" ]; then
        echo ""
        echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}  📁 Backup keys found in: ${BACKUP_DIR}${NC}"
        echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "You have backed up node identity keys. These allow you to restore"
        echo "your node identity if you reinstall Conduit later."
        echo ""
        read -p "Do you want to KEEP your backup keys? (y/n): " keep_confirm < /dev/tty || true

        if [ "$keep_confirm" = "y" ] || [ "$keep_confirm" = "Y" ]; then
            keep_backups=true
            echo -e "${GREEN}✓ Backup keys will be preserved.${NC}"
        else
            echo -e "${YELLOW}⚠ Backup keys will be deleted.${NC}"
        fi
        echo ""
    fi

    echo ""
    echo -e "${BLUE}[INFO]${NC} Stopping Conduit container..."
    docker stop conduit 2>/dev/null || true

    echo -e "${BLUE}[INFO]${NC} Removing Conduit container..."
    docker rm -f conduit 2>/dev/null || true

    echo -e "${BLUE}[INFO]${NC} Removing Conduit Docker image..."
    docker rmi "$CONDUIT_IMAGE" 2>/dev/null || true

    echo -e "${BLUE}[INFO]${NC} Removing Conduit data volume..."
    docker volume rm conduit-data 2>/dev/null || true

    echo -e "${BLUE}[INFO]${NC} Removing auto-start service..."
    # Systemd
    systemctl stop conduit.service 2>/dev/null || true
    systemctl disable conduit.service 2>/dev/null || true
    rm -f /etc/systemd/system/conduit.service
    systemctl daemon-reload 2>/dev/null || true
    # OpenRC / SysVinit
    rc-service conduit stop 2>/dev/null || true
    rc-update del conduit 2>/dev/null || true
    service conduit stop 2>/dev/null || true
    update-rc.d conduit remove 2>/dev/null || true
    chkconfig conduit off 2>/dev/null || true
    rm -f /etc/init.d/conduit

    echo -e "${BLUE}[INFO]${NC} Removing configuration files..."
    if [ "$keep_backups" = true ]; then
        # Keep backup directory, remove everything else in /opt/conduit
        echo -e "${BLUE}[INFO]${NC} Preserving backup keys in ${BACKUP_DIR}..."
        # Remove files in /opt/conduit but keep backups subdirectory
        rm -f /opt/conduit/config.env 2>/dev/null || true
        rm -f /opt/conduit/conduit 2>/dev/null || true
        find /opt/conduit -maxdepth 1 -type f -delete 2>/dev/null || true
    else
        # Remove everything including backups
        rm -rf /opt/conduit
    fi
    rm -f /usr/local/bin/conduit

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    ✅ UNINSTALL COMPLETE!                         ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Conduit and all related components have been removed."
    if [ "$keep_backups" = true ]; then
        echo ""
        echo -e "${CYAN}📁 Your backup keys are preserved in: ${BACKUP_DIR}${NC}"
        echo "   You can use these to restore your node identity after reinstalling."
    fi
    echo ""
    echo "Note: Docker itself was NOT removed."
    echo ""
}

show_menu() {
    local redraw=true
    while true; do
        if [ "$redraw" = true ]; then
            clear
            print_header

            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}  MANAGEMENT OPTIONS${NC}"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "  1. 📈 View status dashboard"
            echo -e "  2. 📊 Live connection stats"
            echo -e "  3. 📋 View logs (filtered)"
            echo -e "  4. ⚙️  Change settings (max-clients, bandwidth)"
            echo ""
            echo -e "  5. 🔄 Update Conduit"
            echo -e "  6. ▶️  Start Conduit"
            echo -e "  7. ⏹️  Stop Conduit"
            echo -e "  8. 🔁 Restart Conduit"
            echo ""
            echo -e "  9. 🌍 View live peers by country (Live Map)"
            echo ""
            echo -e "  h. 🩺 Health check"
            echo -e "  b. 💾 Backup node key"
            echo -e "  r. 📥 Restore node key"
            echo ""
            echo -e "  u. 🗑️  Uninstall (remove everything)"
            echo -e "  v. ℹ️  Version info"
            echo -e "  0. 🚪 Exit"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            redraw=false
        fi
        
        read -p "  Enter choice: " choice < /dev/tty || { echo "Input error. Exiting."; exit 1; }
            
        case $choice in
            1)
                show_dashboard
                redraw=true
                ;;
            2)
                show_live_stats
                redraw=true
                ;;
            3)
                show_logs
                redraw=true
                ;;
            4)
                change_settings
                redraw=true
                ;;
            5)
                update_conduit
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            6)
                start_conduit
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            7)
                stop_conduit
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            8)
                restart_conduit
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            9)
                show_peers
                redraw=true
                ;;
            h|H)
                health_check
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            b|B)
                backup_key
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            r|R)
                restore_key
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            u)
                uninstall_all
                exit 0
                ;;
            v|V)
                show_version
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            0)
                echo "Exiting."
                exit 0
                ;;
            "")
                # Ignore empty Enter key
                ;;
            *)
                echo -e "${RED}Invalid choice: ${NC}${YELLOW}$choice${NC}"
                echo -e "${CYAN}Choose an option from 0-9, h, b, r, u, or v.${NC}"
                ;;
        esac
    done
}

# Command line interface
show_help() {
    echo "Usage: conduit [command]"
    echo ""
    echo "Commands:"
    echo "  status    Show current status with resource usage"
    echo "  stats     View live statistics"
    echo "  logs      View raw Docker logs"
    echo "  health    Run health check on Conduit container"
    echo "  start     Start Conduit container"
    echo "  stop      Stop Conduit container"
    echo "  restart   Restart Conduit container"
    echo "  update    Update to latest Conduit image"
    echo "  settings  Change max-clients/bandwidth"
    echo "  backup    Backup Conduit node identity key"
    echo "  restore   Restore Conduit node identity from backup"
    echo "  uninstall Remove everything (container, data, service)"
    echo "  menu      Open interactive menu (default)"
    echo "  version   Show version information"
    echo "  help      Show this help"
}

show_version() {
    echo "Conduit Manager v${VERSION}"
    echo "Image: ${CONDUIT_IMAGE}"

    # Show actual running image digest if available
    if docker ps 2>/dev/null | grep -q "[[:space:]]conduit$"; then
        local actual=$(docker inspect --format='{{index .RepoDigests 0}}' "$CONDUIT_IMAGE" 2>/dev/null | grep -o 'sha256:[a-f0-9]*')
        if [ -n "$actual" ]; then
            echo "Running Digest:  ${actual}"
        fi
    fi
}

health_check() {
    echo -e "${CYAN}═══ CONDUIT HEALTH CHECK ═══${NC}"
    echo ""

    local all_ok=true

    # 1. Check if Docker is running
    echo -n "Docker daemon:        "
    if docker info &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC} - Docker is not running"
        all_ok=false
    fi

    # 2. Check if container exists
    echo -n "Container exists:     "
    if docker ps -a 2>/dev/null | grep -q "[[:space:]]conduit$"; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC} - Container not found"
        all_ok=false
    fi

    # 3. Check if container is running
    echo -n "Container running:    "
    if docker ps 2>/dev/null | grep -q "[[:space:]]conduit$"; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC} - Container is stopped"
        all_ok=false
    fi

    # 4. Check container health/restart count
    echo -n "Restart count:        "
    local restarts=$(docker inspect --format='{{.RestartCount}}' conduit 2>/dev/null)
    if [ -n "$restarts" ]; then
        if [ "$restarts" -eq 0 ]; then
            echo -e "${GREEN}${restarts}${NC} (healthy)"
        elif [ "$restarts" -lt 5 ]; then
            echo -e "${YELLOW}${restarts}${NC} (some restarts)"
        else
            echo -e "${RED}${restarts}${NC} (excessive restarts)"
            all_ok=false
        fi
    else
        echo -e "${YELLOW}N/A${NC}"
    fi

    # 5. Check if Conduit has connected to network
    echo -n "Network connection:   "
    local connected=$(docker logs --tail 100 conduit 2>&1 | grep -c "Connected to Psiphon" || true)
    if [ "$connected" -gt 0 ]; then
        echo -e "${GREEN}OK${NC} (Connected to Psiphon network)"
    else
        local info_lines=$(docker logs --tail 100 conduit 2>&1 | grep -c "\[INFO\]" || true)
        if [ "$info_lines" -gt 0 ]; then
            echo -e "${YELLOW}CONNECTING${NC} - Establishing connection..."
        else
            echo -e "${YELLOW}WAITING${NC} - Starting up..."
        fi
    fi

    # 5b. Check if STATS output is enabled (requires -v flag)
    echo -n "Stats output:         "
    local stats_count=$(docker logs --tail 100 conduit 2>&1 | grep -c "\[STATS\]" || true)
    if [ "$stats_count" -gt 0 ]; then
        echo -e "${GREEN}OK${NC} (${stats_count} entries)"
    else
        echo -e "${YELLOW}NONE${NC} - Run 'conduit restart' to enable"
    fi

    # 6. Check data volume
    echo -n "Data volume:          "
    if docker volume inspect conduit-data &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC} - Volume not found"
        all_ok=false
    fi

    # 7. Check node key exists
    echo -n "Node identity key:    "
    local mountpoint=$(docker volume inspect conduit-data --format '{{ .Mountpoint }}' 2>/dev/null)
    if [ -n "$mountpoint" ] && [ -f "$mountpoint/conduit_key.json" ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}PENDING${NC} - Will be created on first run"
    fi

    # 8. Check network connectivity (port binding)
    echo -n "Network (host mode):  "
    local network_mode=$(docker inspect --format='{{.HostConfig.NetworkMode}}' conduit 2>/dev/null)
    if [ "$network_mode" = "host" ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}WARN${NC} - Not using host network mode"
    fi

    echo ""
    if [ "$all_ok" = true ]; then
        echo -e "${GREEN}✓ All health checks passed${NC}"
        return 0
    else
        echo -e "${RED}✗ Some health checks failed${NC}"
        return 1
    fi
}

backup_key() {
    echo -e "${CYAN}═══ BACKUP CONDUIT NODE KEY ═══${NC}"
    echo ""

    local mountpoint=$(docker volume inspect conduit-data --format '{{ .Mountpoint }}' 2>/dev/null)

    if [ -z "$mountpoint" ]; then
        echo -e "${RED}Error: Could not find conduit-data volume${NC}"
        return 1
    fi

    if [ ! -f "$mountpoint/conduit_key.json" ]; then
        echo -e "${RED}Error: No node key found. Has Conduit been started at least once?${NC}"
        return 1
    fi

    # Create backup directory
    mkdir -p "$INSTALL_DIR/backups"

    # Create timestamped backup
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_file="$INSTALL_DIR/backups/conduit_key_${timestamp}.json"

    cp "$mountpoint/conduit_key.json" "$backup_file"
    chmod 600 "$backup_file"

    # Get node ID for display
    local node_id=$(cat "$mountpoint/conduit_key.json" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n')

    echo -e "${GREEN}✓ Backup created successfully${NC}"
    echo ""
    echo "  Backup file: ${CYAN}${backup_file}${NC}"
    echo "  Node ID:     ${CYAN}${node_id}${NC}"
    echo ""
    echo -e "${YELLOW}Important:${NC} Store this backup securely. It contains your node's"
    echo "private key which identifies your node on the Psiphon network."
    echo ""

    # List all backups
    echo "All backups:"
    ls -la "$INSTALL_DIR/backups/"*.json 2>/dev/null | awk '{print "  " $9 " (" $5 " bytes)"}'
}

restore_key() {
    echo -e "${CYAN}═══ RESTORE CONDUIT NODE KEY ═══${NC}"
    echo ""

    local backup_dir="$INSTALL_DIR/backups"

    # Check if backup directory exists and has files
    if [ ! -d "$backup_dir" ] || [ -z "$(ls -A $backup_dir/*.json 2>/dev/null)" ]; then
        echo -e "${YELLOW}No backups found in ${backup_dir}${NC}"
        echo ""
        echo "To restore from a custom path, provide the file path:"
        read -p "  Backup file path (or press Enter to cancel): " custom_path < /dev/tty || true

        if [ -z "$custom_path" ]; then
            echo "Restore cancelled."
            return 0
        fi

        if [ ! -f "$custom_path" ]; then
            echo -e "${RED}Error: File not found: ${custom_path}${NC}"
            return 1
        fi

        backup_file="$custom_path"
    else
        # List available backups
        echo "Available backups:"
        local i=1
        local backups=()
        for f in "$backup_dir"/*.json; do
            backups+=("$f")
            local node_id=$(cat "$f" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n' 2>/dev/null)
            echo "  ${i}. $(basename "$f") - Node: ${node_id:-unknown}"
            i=$((i + 1))
        done
        echo ""

        read -p "  Select backup number (or 0 to cancel): " selection < /dev/tty || true

        if [ "$selection" = "0" ] || [ -z "$selection" ]; then
            echo "Restore cancelled."
            return 0
        fi

        if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#backups[@]} ]; then
            echo -e "${RED}Invalid selection${NC}"
            return 1
        fi

        backup_file="${backups[$((selection - 1))]}"
    fi

    echo ""
    echo -e "${YELLOW}Warning:${NC} This will replace the current node key."
    echo "The container will be stopped and restarted."
    echo ""
    read -p "Proceed with restore? [y/N] " confirm < /dev/tty || true

    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        echo "Restore cancelled."
        return 0
    fi

    # Stop container
    echo ""
    echo "Stopping Conduit..."
    docker stop conduit 2>/dev/null || true

    # Get volume mountpoint
    local mountpoint=$(docker volume inspect conduit-data --format '{{ .Mountpoint }}' 2>/dev/null)

    if [ -z "$mountpoint" ]; then
        echo -e "${RED}Error: Could not find conduit-data volume${NC}"
        return 1
    fi

    # Backup current key if exists
    if [ -f "$mountpoint/conduit_key.json" ]; then
        local timestamp=$(date '+%Y%m%d_%H%M%S')
        mkdir -p "$backup_dir"
        cp "$mountpoint/conduit_key.json" "$backup_dir/conduit_key_pre_restore_${timestamp}.json"
        echo "  Current key backed up to: conduit_key_pre_restore_${timestamp}.json"
    fi

    # Restore the key
    cp "$backup_file" "$mountpoint/conduit_key.json"
    chmod 600 "$mountpoint/conduit_key.json"

    # Restart container
    echo "Starting Conduit..."
    docker start conduit 2>/dev/null

    local node_id=$(cat "$mountpoint/conduit_key.json" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n')

    echo ""
    echo -e "${GREEN}✓ Node key restored successfully${NC}"
    echo "  Node ID: ${CYAN}${node_id}${NC}"
}

update_conduit() {
    echo -e "${CYAN}═══ UPDATE CONDUIT ═══${NC}"
    echo ""

    echo "Current image: ${CONDUIT_IMAGE}"
    echo ""

    # Check for updates by pulling
    echo "Checking for updates..."
    if ! docker pull $CONDUIT_IMAGE 2>/dev/null; then
        echo -e "${RED}Failed to check for updates. Check your internet connection.${NC}"
        return 1
    fi


    echo ""
    echo "Recreating container with updated image..."

    # Save if container was running
    local was_running=false
    if docker ps 2>/dev/null | grep -q "[[:space:]]conduit$"; then
        was_running=true
    fi

    # Remove old container
    docker rm -f conduit 2>/dev/null || true

    fix_volume_permissions
    run_conduit_container

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Conduit updated and restarted${NC}"
    else
        echo -e "${RED}✗ Failed to start updated container${NC}"
        return 1
    fi
}

case "${1:-menu}" in
    status)   show_status ;;
    stats)    show_live_stats ;;
    logs)     show_logs ;;
    health)   health_check ;;
    start)    start_conduit ;;
    stop)     stop_conduit ;;
    restart)  restart_conduit ;;
    update)   update_conduit ;;
    peers)    show_peers ;;
    settings) change_settings ;;
    backup)   backup_key ;;
    restore)  restore_key ;;
    uninstall) uninstall_all ;;
    version|-v|--version) show_version ;;
    help|-h|--help) show_help ;;
    menu|*)   show_menu ;;
esac
MANAGEMENT

    # Patch the INSTALL_DIR in the generated script
    sed -i "s#REPLACE_ME_INSTALL_DIR#$INSTALL_DIR#g" "$INSTALL_DIR/conduit"
    
    chmod +x "$INSTALL_DIR/conduit"
    # Force create symlink
    rm -f /usr/local/bin/conduit 2>/dev/null || true
    ln -s "$INSTALL_DIR/conduit" /usr/local/bin/conduit
    
    log_success "Management script installed: conduit"
}

#═══════════════════════════════════════════════════════════════════════
# Summary
#═══════════════════════════════════════════════════════════════════════

print_summary() {
    local init_type="Enabled"
    if [ "$HAS_SYSTEMD" = "true" ]; then
        init_type="Enabled (systemd)"
    elif command -v rc-update &>/dev/null; then
        init_type="Enabled (OpenRC)"
    elif [ -d /etc/init.d ]; then
        init_type="Enabled (SysVinit)"
    fi
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    ✅ INSTALLATION COMPLETE!                      ║${NC}"
    echo -e "${GREEN}╠═══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  Conduit is running and ready to help users!                      ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                                   ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  📊 Settings:                                                     ${GREEN}║${NC}"
    printf "${GREEN}║${NC}     Max Clients: ${CYAN}%-4s${NC}                                             ${GREEN}║${NC}\n" "${MAX_CLIENTS}"
    if [ "$BANDWIDTH" == "-1" ]; then
        echo -e "${GREEN}║${NC}     Bandwidth:   ${CYAN}Unlimited${NC}                                        ${GREEN}║${NC}"
    else
        printf "${GREEN}║${NC}     Bandwidth:   ${CYAN}%-4s${NC} Mbps                                        ${GREEN}║${NC}\n" "${BANDWIDTH}"
    fi
    printf "${GREEN}║${NC}     Auto-start:  ${CYAN}%-20s${NC}                             ${GREEN}║${NC}\n" "${init_type}"
    echo -e "${GREEN}║${NC}                                                                   ${GREEN}║${NC}"
    echo -e "${GREEN}╠═══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  COMMANDS:                                                        ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                                   ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit${NC}               # Open management menu                    ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit stats${NC}         # View live statistics + CPU/RAM          ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit status${NC}        # Quick status with resource usage        ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit logs${NC}          # View raw logs                           ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit settings${NC}      # Change max-clients/bandwidth            ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit uninstall${NC}     # Remove everything                       ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                                   ${GREEN}║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${YELLOW}View live stats now:${NC} conduit stats"
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# Uninstall Function
#═══════════════════════════════════════════════════════════════════════

uninstall() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo "║                    ⚠️  UNINSTALL CONDUIT                          ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "This will completely remove:"
    echo "  • Conduit Docker container"
    echo "  • Conduit Docker image"
    echo "  • Conduit data volume (all stored data)"
    echo "  • Auto-start service (systemd/OpenRC/SysVinit)"
    echo "  • Configuration files"
    echo "  • Management CLI"
    echo ""
    echo -e "${RED}WARNING: This action cannot be undone!${NC}"
    echo ""
    read -p "Are you sure you want to uninstall? (type 'yes' to confirm): " confirm < /dev/tty || true
    
    if [ "$confirm" != "yes" ]; then
        echo "Uninstall cancelled."
        exit 0
    fi
    
    echo ""
    log_info "Stopping Conduit container..."
    docker stop conduit 2>/dev/null || true
    
    log_info "Removing Conduit container..."
    docker rm -f conduit 2>/dev/null || true
    
    log_info "Removing Conduit Docker image..."
    docker rmi "$CONDUIT_IMAGE" 2>/dev/null || true
    
    log_info "Removing Conduit data volume..."
    docker volume rm conduit-data 2>/dev/null || true
    
    log_info "Removing auto-start service..."
    # Systemd
    systemctl stop conduit.service 2>/dev/null || true
    systemctl disable conduit.service 2>/dev/null || true
    rm -f /etc/systemd/system/conduit.service
    systemctl daemon-reload 2>/dev/null || true
    # OpenRC / SysVinit
    rc-service conduit stop 2>/dev/null || true
    rc-update del conduit 2>/dev/null || true
    service conduit stop 2>/dev/null || true
    update-rc.d conduit remove 2>/dev/null || true
    chkconfig conduit off 2>/dev/null || true
    rm -f /etc/init.d/conduit
    
    log_info "Removing configuration files..."
    rm -rf "$INSTALL_DIR"
    rm -f /usr/local/bin/conduit
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    ✅ UNINSTALL COMPLETE!                         ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Conduit and all related components have been removed."
    echo ""
    echo "Note: Docker itself was NOT removed."
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# Main
#═══════════════════════════════════════════════════════════════════════

show_usage() {
    echo "Psiphon Conduit Manager v${VERSION}"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  (no args)      Install or open management menu if already installed"
    echo "  --reinstall    Force fresh reinstall"
    echo "  --uninstall    Completely remove Conduit and all components"
    echo "  --help, -h     Show this help message"
    echo ""
    echo "Examples:"
    echo "  sudo bash $0              # Install or open menu"
    echo "  sudo bash $0 --reinstall  # Fresh install"
    echo "  sudo bash $0 --uninstall  # Remove everything"
    echo ""
    echo "After install, use: conduit"
}

main() {
    # Handle command line arguments
    case "${1:-}" in
        --uninstall|-u)
            check_root
            uninstall
            exit 0
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        --reinstall)
            # Force reinstall
            FORCE_REINSTALL=true
            ;;
    esac
    
    print_header
    check_root
    detect_os
    
    # Ensure all tools (including new ones like tcpdump) are present
    check_dependencies
    
    # Check if already installed
    if [ -f "$INSTALL_DIR/conduit" ] && [ "$FORCE_REINSTALL" != "true" ]; then
        echo -e "${GREEN}Conduit is already installed!${NC}"
        echo ""
        echo "What would you like to do?"
        echo ""
        echo "  1. 📊 Open management menu"
        echo "  2. 🔄 Reinstall (fresh install)"
        echo "  3. 🗑️  Uninstall"
        echo "  0. 🚪 Exit"
        echo ""
        read -p "  Enter choice: " choice < /dev/tty || true
        
        case $choice in
            1)
                echo -e "${CYAN}Updating management script and opening menu...${NC}"
                create_management_script
                exec "$INSTALL_DIR/conduit" menu
                ;;
            2)
                echo ""
                log_info "Starting fresh reinstall..."
                ;;
            3)
                uninstall
                exit 0
                ;;
            0)
                echo "Exiting."
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid choice: ${NC}${YELLOW}$choice${NC}"
                echo -e "${CYAN}Returning to installer...${NC}"
                sleep 1
                main "$@"
                ;;
        esac
    fi

    # Interactive settings prompt (max-clients, bandwidth)
    prompt_settings

    echo ""
    echo -e "${CYAN}Starting installation...${NC}"
    echo ""

    #───────────────────────────────────────────────────────────────
    # Installation Steps (5 steps if backup exists, otherwise 4)
    #───────────────────────────────────────────────────────────────

    # Step 1: Install Docker (if not already installed)
    log_info "Step 1/5: Installing Docker..."
    install_docker

    echo ""

    # Step 2: Check for and optionally restore backup keys
    # This preserves node identity if user had a previous installation
    log_info "Step 2/5: Checking for previous node identity..."
    check_and_offer_backup_restore

    echo ""

    # Step 3: Start Conduit container
    log_info "Step 3/5: Starting Conduit..."
    run_conduit
    
    echo ""

    # Step 4: Save settings and configure auto-start service
    log_info "Step 4/5: Setting up auto-start..."
    save_settings
    setup_autostart

    echo ""

    # Step 5: Create the 'conduit' CLI management script
    log_info "Step 5/5: Creating management script..."
    create_management_script

    print_summary

    read -p "Open management menu now? [Y/n] " open_menu < /dev/tty || true
    if [[ ! "$open_menu" =~ ^[Nn] ]]; then
        "$INSTALL_DIR/conduit" menu
    fi
}
#
# REACHED END OF SCRIPT - VERSION 1.0.2
# ###############################################################################
main "$@"
