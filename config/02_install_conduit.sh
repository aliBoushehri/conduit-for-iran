#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════
#  STEP 2: Install Psiphon Conduit Manager
#
#  Purpose: Steps to install Conduit Manager using the official script and
#           configure firewall rules.
#
#  Usage: sudo bash 02_install_conduit.sh
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
    clear
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║           PSIPHON CONDUIT MANAGER INSTALLATION                    ║"
    echo "║           Helping Users Bypass Internet Censorship                ║"
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
# STEP 1: Check Prerequisites
#═══════════════════════════════════════════════════════════════════════════════
check_prerequisites() {
    log_step "STEP 1: Checking Prerequisites"
    
    # Check if first setup script was run
    if ! command -v ufw &> /dev/null || ! systemctl is-active --quiet fail2ban; then
        log_warn "It seems you haven't run 01_server_setup.sh yet"
        read -p "Continue anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_error "Please run 01_server_setup.sh first"
            exit 1
        fi
    fi
    
    # Check required tools for valid installation
    local required_tools=("curl" "tar")
    local missing_tools=()
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "Missing required tools for installation: ${missing_tools[*]}"
        log_info "Installing missing tools..."
        apt update && apt install -y "${missing_tools[@]}"
    fi
    
    log_success "Prerequisites checked"
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 2: Install Conduit Manager (Official Script)
#═══════════════════════════════════════════════════════════════════════════════
install_conduit() {
    log_step "STEP 2: Installing Conduit Manager"
    
    echo -e "${CYAN}Select Conduit Manager Version:${NC}"
    echo -e "  1) ${GREEN}Latest Version${NC} (Official, Multi-container)"
    echo -e "  2) ${GREEN}Version 1.0.2${NC} (Bypassing Multi-container complexity)"
    echo ""
    read -p "Enter your choice [1-2]: " version_choice

    case $version_choice in
        1)
            log_info "Launching official Conduit Manager installer (Latest)..."
            log_warn "This will start an interactive installation process."
            log_warn "Please follow the on-screen instructions."
            echo ""
            
            # Run the official installer
            curl -sL https://raw.githubusercontent.com/SamNet-dev/conduit-manager/main/conduit.sh | sudo bash
            ;;
        2)
            log_info "Installing Conduit Manager v1.0.2..."
            
            # Check if local script exists
            if [ -f "conduit.1.0.2.sh" ]; then
                bash conduit.1.0.2.sh
            else
                log_error "File 'conduit.1.0.2.sh' not found in current directory!"
                log_info "Please ensure the file exists and try again."
                exit 1
            fi
            ;;
        *)
            log_error "Invalid choice. Exiting."
            exit 1
            ;;
    esac

    if [ $? -eq 0 ]; then
        log_success "Conduit Manager installation finished."
    else
        log_error "Conduit Manager installation failed or was cancelled."
        exit 1
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 3: Configure Firewall for Conduit
#═══════════════════════════════════════════════════════════════════════════════
configure_firewall() {
    log_step "STEP 3: Configuring Firewall for Conduit"
    
    log_info "Ensuring Conduit ports are open in UFW..."
    
    # Open ports for Conduit protocols
    ufw allow 4000/tcp comment 'Conduit SSH'
    ufw allow 4001/tcp comment 'Conduit OSSH'
    ufw allow 443/tcp comment 'Conduit MEEK'
    ufw allow 443/udp comment 'Conduit MEEK UDP'
    
    # Allow high port range for additional protocols/containers
    ufw allow 4002:4100/tcp comment 'Conduit Extra Ports'
    ufw allow 4002:4100/udp comment 'Conduit Extra UDP'
    
    log_success "Firewall rules updated"
    
    echo ""
    log_info "Current firewall status for Conduit:"
    ufw status numbered | grep -E '(Conduit|4000|4001|443)' || echo "No specific rules found yet."
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 4: Show Summary and Next Steps
#═══════════════════════════════════════════════════════════════════════════════
show_summary() {
    log_step "INSTALLATION & CONFIGURATION COMPLETED!"
    
    # Get server info
    PUBLIC_IP=$(curl -s https://api.ipify.org || echo "Unknown")
    
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                  INSTALLATION SUMMARY                             ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}✓${NC} Conduit Manager installed via official script"
    echo -e "${GREEN}✓${NC} Firewall configured for Conduit ports"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}MANAGEMENT:${NC}"
    echo ""
    echo "  To manage Conduit (start, stop, logs, menu), simply run:"
    echo "    ${BLUE}conduit${NC}"
    echo ""
    echo "  Or use full path if not in PATH:"
    echo "    ${BLUE}/opt/conduit/conduit${NC}"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}NEXT STEPS:${NC}"
    echo ""
    echo "  1. Apply Iran-only firewall rules (RECOMMENDED):"
    echo "     ${BLUE}sudo bash 03_setup_iran_firewall.sh${NC}"
    echo ""
    echo "  2. Register your server with Psiphon network:"
    echo "     ${BLUE}Visit: https://psiphon.ca/en/sponsor.html${NC}"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    log_success "Conduit Manager setup is complete!"
    echo ""
}

#═══════════════════════════════════════════════════════════════════════════════
# Main Execution
#═══════════════════════════════════════════════════════════════════════════════
main() {
    print_header
    check_root
    
    echo -e "${YELLOW}This script will install Psiphon Conduit Manager${NC}"
    echo -e "${YELLOW}using the official installer and configure necessary firewall rules.${NC}"
    echo ""
    read -p "Continue with installation? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_error "Installation cancelled by user"
        exit 1
    fi
    
    # Execute installation steps
    check_prerequisites
    install_conduit
    configure_firewall
    
    # Show summary
    show_summary
}

# Run main function
main
