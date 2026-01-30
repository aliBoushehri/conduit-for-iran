#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════
#  STEP 3: Setup Iran-Only Firewall for Conduit
#
#  Purpose: Configure iptables/ipset to prioritize Iranian traffic
#           This maximizes bandwidth for users in Iran during shutdowns
#
#  Usage: sudo bash 03_setup_iran_firewall.sh
#═══════════════════════════════════════════════════════════════════════════════

set -e  # Exit on any error

# Configuration
FIREWALL_SCRIPT_URL="https://raw.githubusercontent.com/SamNet-dev/conduit-manager/main/scripts/iran_firewall_linux.sh"
INSTALL_DIR="/opt/conduit-firewall"
SCRIPT_NAME="iran_firewall_linux.sh"

# Determine script directory to find local files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    echo "║        IRAN-ONLY FIREWALL SETUP FOR CONDUIT                      ║"
    echo "║        Maximize Bandwidth for Iranian Users                       ║"
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
# STEP 1: Check if Conduit is Installed
#═══════════════════════════════════════════════════════════════════════════════
check_conduit() {
    log_step "STEP 1: Checking Conduit Installation"
    
    # We check if the container is running OR if the service file exists
    if ! docker ps | grep -q conduit && [[ ! -f /etc/systemd/system/conduit.service ]]; then
        log_warn "Conduit does not appear to be running."
        log_info "Recommendation: Run 02_install_conduit.sh first."
        read -p "Continue anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        log_success "Conduit appears to be installed."
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 2: Install Firewall Dependencies
#═══════════════════════════════════════════════════════════════════════════════
install_dependencies() {
    log_step "STEP 2: Installing Firewall Dependencies"
    
    local packages=("iptables" "ipset" "curl" "iproute2")
    local missing=()
    
    for pkg in "${packages[@]}"; do
        if ! command -v "${pkg}" &> /dev/null; then
            missing+=("$pkg")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_info "Installing: ${missing[*]}"
        apt update
        apt install -y "${missing[@]}"
    else
        log_success "All dependencies already installed"
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 3: Copy Uploaded Firewall Script
#═══════════════════════════════════════════════════════════════════════════════
copy_firewall_script() {
    log_step "STEP 3: Setting Up Firewall Script"
    
    # Create installation directory
    mkdir -p "$INSTALL_DIR"
    
    # Look for script in the same directory as THIS setup script
    LOCAL_SCRIPT="$SCRIPT_DIR/$SCRIPT_NAME"
    
    if [ -f "$LOCAL_SCRIPT" ]; then
        log_info "Found firewall script locally: $LOCAL_SCRIPT"
        cp "$LOCAL_SCRIPT" "$INSTALL_DIR/$SCRIPT_NAME"
    else
        log_warn "Firewall script not found locally ($LOCAL_SCRIPT)"
        log_info "Attempting to download from GitHub..."
        
        # Try to download from GitHub
        if wget -q "$FIREWALL_SCRIPT_URL" -O "$INSTALL_DIR/$SCRIPT_NAME"; then
            log_success "Downloaded from GitHub"
        else
            log_error "Could not download firewall script and local file missing."
            log_info "Please ensure '$SCRIPT_NAME' is in the same folder as this script."
            exit 1
        fi
    fi
    
    # Make executable
    chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
    
    log_success "Firewall script ready at $INSTALL_DIR/$SCRIPT_NAME"
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 4: Create Automated Enable Script
#═══════════════════════════════════════════════════════════════════════════════
create_enable_script() {
    log_step "STEP 4: Creating Automated Enable Script"
    
    cat > "$INSTALL_DIR/enable_iran_firewall.sh" <<'ENABLE_SCRIPT'
#!/bin/bash
# Auto-enable Iran-only firewall (Normal Mode)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Source the main firewall script functions
source ./iran_firewall_linux.sh

echo "═══════════════════════════════════════════════════════════════"
echo "  Enabling Iran-Only Firewall in Normal Mode"
echo "  (TCP: Global, UDP: Iran-only)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Enable in normal mode
enable_iran_only "false"

echo ""
echo "✓ Iran-only firewall enabled successfully!"
echo ""
ENABLE_SCRIPT
    
    chmod +x "$INSTALL_DIR/enable_iran_firewall.sh"
    
    log_success "Enable script created"
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 5: Create Automated Enable Strict Script
#═══════════════════════════════════════════════════════════════════════════════
create_strict_script() {
    log_step "STEP 5: Creating Strict Mode Script"
    
    cat > "$INSTALL_DIR/enable_strict_mode.sh" <<'STRICT_SCRIPT'
#!/bin/bash
# Enable Iran-only firewall in STRICT mode (TCP + UDP restricted)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Source the main firewall script functions
source ./iran_firewall_linux.sh

echo "═══════════════════════════════════════════════════════════════"
echo "  Enabling Iran-Only Firewall in STRICT Mode"
echo "  (TCP + UDP: Iran-only)"
echo "  ⚠️  WARNING: May reduce broker visibility"
echo "═══════════════════════════════════════════════════════════════"
echo ""

read -p "Continue with STRICT mode? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# Enable in strict mode
enable_iran_only "true"

echo ""
echo "✓ Strict mode enabled successfully!"
echo ""
STRICT_SCRIPT
    
    chmod +x "$INSTALL_DIR/enable_strict_mode.sh"
    
    log_success "Strict mode script created"
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 6: Create Management Scripts
#═══════════════════════════════════════════════════════════════════════════════
create_management_scripts() {
    log_step "STEP 6: Creating Management Scripts"
    
    # Disable script
    cat > "$INSTALL_DIR/disable_iran_firewall.sh" <<'DISABLE_SCRIPT'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source ./iran_firewall_linux.sh
disable_iran_only
DISABLE_SCRIPT
    
    # Status script
    cat > "$INSTALL_DIR/check_status.sh" <<'STATUS_SCRIPT'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source ./iran_firewall_linux.sh
show_status
STATUS_SCRIPT
    
    # Save rules script
    cat > "$INSTALL_DIR/save_rules.sh" <<'SAVE_SCRIPT'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source ./iran_firewall_linux.sh
save_rules
SAVE_SCRIPT
    
    chmod +x "$INSTALL_DIR"/*.sh
    
    log_success "Management scripts created"
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 7: Create Systemd Service for Persistence
#═══════════════════════════════════════════════════════════════════════════════
create_systemd_service() {
    log_step "STEP 7: Creating Systemd Service for Persistence"
    
    cat > /etc/systemd/system/iran-firewall.service <<EOF
[Unit]
Description=Iran-Only Firewall for Psiphon Conduit
After=network-online.target conduit.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$INSTALL_DIR/enable_iran_firewall.sh
ExecStop=$INSTALL_DIR/disable_iran_firewall.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    
    log_success "Systemd service created"
    log_info "Service will NOT auto-start yet - enable it manually if needed"
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 8: Show Summary and Next Steps
#═══════════════════════════════════════════════════════════════════════════════
show_summary() {
    log_step "FIREWALL SETUP COMPLETED!"
    
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    SETUP SUMMARY                                  ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}✓${NC} Firewall script installed to: $INSTALL_DIR"
    echo -e "${GREEN}✓${NC} Dependencies installed"
    echo -e "${GREEN}✓${NC} Management scripts created"
    echo -e "${GREEN}✓${NC} Systemd service configured"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}FIREWALL MODES:${NC}"
    echo ""
    echo "  📡 ${GREEN}NORMAL MODE${NC} (Recommended)"
    echo "     • TCP: Global (allows broker discovery)"
    echo "     • UDP: Iran-only (main data tunnel)"
    echo "     • Best for most users"
    echo ""
    echo "  🔒 ${YELLOW}STRICT MODE${NC}"
    echo "     • TCP + UDP: Iran-only"
    echo "     • Maximum restriction"
    echo "     • May reduce broker visibility"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}QUICK START COMMANDS:${NC}"
    echo ""
    echo "  Enable firewall (Normal mode - RECOMMENDED):"
    echo "    ${BLUE}cd $INSTALL_DIR && sudo ./enable_iran_firewall.sh${NC}"
    echo ""
    echo "  Enable firewall (Strict mode):"
    echo "    ${BLUE}cd $INSTALL_DIR && sudo ./enable_strict_mode.sh${NC}"
    echo ""
    echo "  Check status:"
    echo "    ${BLUE}cd $INSTALL_DIR && sudo ./check_status.sh${NC}"
    echo ""
    echo "  Disable firewall:"
    echo "    ${BLUE}cd $INSTALL_DIR && sudo ./disable_iran_firewall.sh${NC}"
    echo ""
    echo "  Save rules (for persistence across reboots):"
    echo "    ${BLUE}cd $INSTALL_DIR && sudo ./save_rules.sh${NC}"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}AUTOMATIC STARTUP (Optional):${NC}"
    echo ""
    echo "  Enable automatic firewall on boot:"
    echo "    ${BLUE}sudo systemctl enable iran-firewall${NC}"
    echo ""
    echo "  Disable automatic startup:"
    echo "    ${BLUE}sudo systemctl disable iran-firewall${NC}"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}WHAT THIS DOES:${NC}"
    echo ""
    echo "  • Allows ONLY Iranian IP addresses to connect via UDP"
    echo "  • UDP is the main data tunnel (high bandwidth usage)"
    echo "  • Blocks non-Iranian traffic on Conduit ports"
    echo "  • Your other services (SSH, etc.) are NOT affected"
    echo "  • Maximizes your bandwidth for users in Iran"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}NEXT STEPS:${NC}"
    echo ""
    echo "  1. Enable the firewall NOW:"
    echo "     ${BLUE}cd $INSTALL_DIR && sudo ./enable_iran_firewall.sh${NC}"
    echo ""
    echo "  2. Verify it's working:"
    echo "     ${BLUE}cd $INSTALL_DIR && sudo ./check_status.sh${NC}"
    echo ""
    echo "  3. (Optional) Enable auto-start on boot:"
    echo "     ${BLUE}sudo systemctl enable iran-firewall${NC}"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    log_warn "IMPORTANT: The firewall is NOT enabled yet!"
    log_info "Run the enable script when you're ready to activate it"
    log_info "The script will automatically detect running Conduit ports"
    echo ""
}

#═══════════════════════════════════════════════════════════════════════════════
# STEP 9: Prompt to Enable Immediately
#═══════════════════════════════════════════════════════════════════════════════
prompt_enable_now() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}               🚀  ACTIVATE FIREWALL NOW?  🚀               ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "The installation is complete, but the firewall is currently DISABLED."
    echo ""
    echo -e "Would you like to enable ${GREEN}Normal Mode${NC} (Iran-only UDP, Global TCP) now?"
    echo ""
    
    read -p "Enable firewall? (y/n): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_step "Activating Firewall..."
        # Run the enable script we just created
        bash "$INSTALL_DIR/enable_iran_firewall.sh"
        
        # Check if it worked
        if [ $? -eq 0 ]; then
             echo ""
             echo -e "${GREEN}🎉 SETUP AND ACTIVATION COMPLETE!${NC}"
             # Show status
             bash "$INSTALL_DIR/check_status.sh"
        fi
    else
        log_info "Okay, keeping firewall DISABLED for now."
        log_info "You can enable it later with: sudo $INSTALL_DIR/enable_iran_firewall.sh"
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# Main Execution
#═══════════════════════════════════════════════════════════════════════════════
main() {
    print_header
    check_root
    
    echo -e "${YELLOW}This script will setup the Iran-only firewall for Conduit${NC}"
    echo -e "${YELLOW}to maximize bandwidth for users in censored regions.${NC}"
    echo ""
    echo "The firewall will:"
    echo "  • Allow only Iranian IPs to connect via UDP (main tunnel)"
    echo "  • Keep TCP open globally (for broker discovery)"
    echo "  • Only affect Conduit's ports (other services unaffected)"
    echo ""
    read -p "Continue with setup? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_error "Setup cancelled by user"
        exit 1
    fi
    
    # Execute setup steps
    check_conduit
    install_dependencies
    copy_firewall_script
    create_enable_script
    create_strict_script
    create_management_scripts
    create_systemd_service
    
    # Show summary
    show_summary
    
    # Prompt to enable
    prompt_enable_now
}

# Run main function
main
