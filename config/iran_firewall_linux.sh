#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════
#       IRAN-ONLY FIREWALL FOR PSIPHON CONDUIT - LINUX VERSION v1.2.0
#
#  Maximize your bandwidth for Iranian users by blocking
#  connections from other countries.
#
#  ⚠️  ONLY affects traffic on Conduit's listening port(s)
#  ✅ Your server's other services work normally
#
#  Requires: iptables, ip6tables, ipset, curl, root privileges
#
#  GitHub: Share this script to help more people!
#═══════════════════════════════════════════════════════════════════════════════

VERSION="1.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config_linux.json"
LOG_FILE="$SCRIPT_DIR/firewall_linux.log"
IPSET_V4="iran_ipv4"
IPSET_V6="iran_ipv6"
CHAIN_NAME="IRAN_CONDUIT"

# Conduit process name for auto-detection
CONDUIT_PROCESS="conduit-tunnel-core"

# Default port range if auto-detection fails (Psiphon commonly uses these)
DEFAULT_PORT_RANGE="1024:65535"

# IP sources for Iran ranges
IP_SOURCES_V4=(
    "https://www.ipdeny.com/ipblocks/data/countries/ir.zone"
    "https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ir.cidr"
)

IP_SOURCES_V6=(
    "https://www.ipdeny.com/ipv6/ipaddresses/blocks/ir.zone"
    "https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv6/ir.cidr"
)

# DNS servers to whitelist
DNS_SERVERS_V4=(
    "8.8.8.8" "8.8.4.4"                     # Google DNS
    "1.1.1.1" "1.0.0.1"                     # Cloudflare DNS
    "9.9.9.9" "149.112.112.112"             # Quad9 DNS
    "208.67.222.222" "208.67.220.220"       # OpenDNS
    "4.2.2.1" "4.2.2.2"                     # Level3 DNS
    "178.22.122.100" "185.51.200.2"         # Shekan DNS (Iran)
    "10.202.10.202" "10.202.10.102"         # 403.online DNS (Iran)
)

DNS_SERVERS_V6=(
    "2001:4860:4860::8888" "2001:4860:4860::8844"  # Google DNS
    "2606:4700:4700::1111" "2606:4700:4700::1001"  # Cloudflare DNS
    "2620:fe::fe" "2620:fe::9"                      # Quad9 DNS
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

#═══════════════════════════════════════════════════════════════════════════════
# Utility Functions
#═══════════════════════════════════════════════════════════════════════════════

log() {
    local msg="$(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo "$msg" >> "$LOG_FILE"
    echo -e "$1"
}

print_header() {
    clear
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║       🇮🇷 IRAN-ONLY FIREWALL FOR PSIPHON CONDUIT v$VERSION 🇮🇷        ║"
    echo "╠═══════════════════════════════════════════════════════════════════╣"
    echo "║  Maximize bandwidth for Iranian users during internet shutdowns   ║"
    echo "║  [LINUX VERSION - Uses iptables/ipset]                            ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ ERROR: This script must be run as root!${NC}"
        echo "   Use: sudo $0"
        exit 1
    fi
}

check_dependencies() {
    local missing=()

    for cmd in iptables ip6tables ipset curl ss; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}❌ Missing dependencies: ${missing[*]}${NC}"
        echo ""
        echo "Install them with:"
        echo "  Debian/Ubuntu: sudo apt install iptables ipset curl iproute2"
        echo "  RHEL/CentOS:   sudo yum install iptables ipset curl iproute"
        echo "  Arch:          sudo pacman -S iptables ipset curl iproute2"
        exit 1
    fi

    echo -e "${GREEN}✅ All dependencies installed${NC}"
}

#═══════════════════════════════════════════════════════════════════════════════
# Conduit Port Detection
#═══════════════════════════════════════════════════════════════════════════════

detect_conduit_ports() {
    # Try to find Conduit's listening ports
    echo -e "\n${BLUE}🔍 Detecting Conduit listening ports...${NC}"

    local ports=()

    # Method 1: Check Docker containers (Priority for modern setups)
    if command -v docker &>/dev/null; then
        local containers=("conduit" "shadowbox" "psiphon-tunnel-core")
        
        for name in "${containers[@]}"; do
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
                echo "   Found running Docker container: $name"
                
                # Extract public host ports using docker inspect
                # detailed format: loops through ports, prints HostPort if it exists
                local docker_ports=$(docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}} {{end}}{{end}}' "$name" 2>/dev/null)
                
                for p in $docker_ports; do
                    # Clean up and validate
                    p=$(echo "$p" | tr -cd '0-9')
                    if [[ -n "$p" ]] && [[ ! " ${ports[*]} " =~ " $p " ]]; then
                        ports+=("$p")
                    fi
                done
            fi
        done
        
        if [[ ${#ports[@]} -gt 0 ]]; then
            echo -e "   ${GREEN}✅ Detected Docker ports: ${ports[*]}${NC}"
        fi
    fi

    # Method 2: Find by process name using ss (Legacy/Native)
    if [[ ${#ports[@]} -eq 0 ]] && pgrep -x "$CONDUIT_PROCESS" &>/dev/null; then
        echo "   Found running Conduit process (native)"

        # Get PIDs
        local pids=$(pgrep -x "$CONDUIT_PROCESS")

        for pid in $pids; do
            # Get listening ports for this PID (UDP and TCP)
            local proc_ports=$(ss -tlnup 2>/dev/null | grep "pid=$pid" | awk '{print $5}' | grep -oE '[0-9]+$' | sort -u)
            for p in $proc_ports; do
                [[ ! " ${ports[*]} " =~ " $p " ]] && ports+=("$p")
            done
        done

        # Also check with netstat as backup
        if [[ ${#ports[@]} -eq 0 ]] && command -v netstat &>/dev/null; then
            for pid in $pids; do
                local proc_ports=$(netstat -tlnup 2>/dev/null | grep "$pid/" | awk '{print $4}' | grep -oE '[0-9]+$' | sort -u)
                for p in $proc_ports; do
                    [[ ! " ${ports[*]} " =~ " $p " ]] && ports+=("$p")
                done
            done
        fi
    fi

    # Method 2: Look for common Psiphon config files
    if [[ ${#ports[@]} -eq 0 ]]; then
        local config_locations=(
            "/opt/psiphon/psiphond.config"
            "/etc/psiphon/psiphond.config"
            "$HOME/.psiphon/psiphond.config"
            "./psiphond.config"
        )

        for cfg in "${config_locations[@]}"; do
            if [[ -f "$cfg" ]]; then
                echo "   Found config: $cfg"
                # Extract TunnelProtocolPorts from JSON config
                local cfg_ports=$(grep -oE '"[^"]*Port[^"]*"\s*:\s*[0-9]+' "$cfg" 2>/dev/null | grep -oE '[0-9]+$')
                for p in $cfg_ports; do
                    [[ ! " ${ports[*]} " =~ " $p " ]] && ports+=("$p")
                done
            fi
        done
    fi

    if [[ ${#ports[@]} -gt 0 ]]; then
        echo -e "   ${GREEN}✅ Detected ports: ${ports[*]}${NC}"
        CONDUIT_PORTS=("${ports[@]}")
        return 0
    else
        echo -e "   ${YELLOW}⚠️  Could not auto-detect ports${NC}"
        return 1
    fi
}

prompt_for_ports() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}IMPORTANT: Port Configuration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "   This script ONLY affects traffic on the specified port(s)."
    echo "   All other services on your server will work normally."
    echo ""
    echo "   Options:"
    echo "   1. Enter specific port(s) that Conduit listens on"
    echo "   2. Use a port range (e.g., 8000:9000)"
    echo "   3. Press Enter to apply to ALL ports (not recommended)"
    echo ""
    echo "   Examples:"
    echo "   - Single port:    443"
    echo "   - Multiple ports: 443,8080,9001"
    echo "   - Port range:     8000:9000"
    echo ""

    read -p "   Enter Conduit port(s) [or Enter for all]: " user_ports

    if [[ -z "$user_ports" ]]; then
        echo ""
        echo -e "${YELLOW}   ⚠️  WARNING: Applying to ALL ports affects your entire server!${NC}"
        read -p "   Are you sure? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            echo "   Aborted."
            return 1
        fi
        CONDUIT_PORTS=()
        return 0
    fi

    # Parse user input into array
    CONDUIT_PORTS=()
    IFS=',' read -ra port_parts <<< "$user_ports"
    for part in "${port_parts[@]}"; do
        part=$(echo "$part" | tr -d ' ')
        CONDUIT_PORTS+=("$part")
    done

    echo -e "   ${GREEN}✅ Will apply rules to port(s): ${CONDUIT_PORTS[*]}${NC}"
    return 0
}

get_conduit_ports() {
    # Try auto-detection first
    if detect_conduit_ports; then
        echo ""
        read -p "   Use detected ports? (y/n): " use_detected
        if [[ "$use_detected" == "y" || "$use_detected" == "Y" ]]; then
            return 0
        fi
    fi

    # Fall back to manual input
    prompt_for_ports
}

is_conduit_running() {
    pgrep -x "$CONDUIT_PROCESS" &>/dev/null
}

#═══════════════════════════════════════════════════════════════════════════════
# IP Download Functions
#═══════════════════════════════════════════════════════════════════════════════

download_iran_ips() {
    local include_ipv6="${1:-true}"
    local ipv4_file="/tmp/iran_ipv4.txt"
    local ipv6_file="/tmp/iran_ipv6.txt"

    echo -e "\n${BLUE}📥 Downloading Iran IP ranges...${NC}"

    # Clear temp files
    > "$ipv4_file"
    > "$ipv6_file"

    # Download IPv4
    echo -e "\n   ${CYAN}IPv4 ranges:${NC}"
    for url in "${IP_SOURCES_V4[@]}"; do
        local source_name=$(basename "$url")
        echo -n "   Fetching $source_name... "

        if curl -s --max-time 30 -A "IranFirewall/$VERSION" "$url" 2>/dev/null | \
           grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' >> "$ipv4_file"; then
            local count=$(wc -l < "$ipv4_file")
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${RED}✗${NC}"
        fi
    done

    # Remove duplicates
    sort -u "$ipv4_file" -o "$ipv4_file"
    local ipv4_count=$(wc -l < "$ipv4_file")

    # Download IPv6
    if [[ "$include_ipv6" == "true" ]]; then
        echo -e "\n   ${CYAN}IPv6 ranges:${NC}"
        for url in "${IP_SOURCES_V6[@]}"; do
            local source_name=$(basename "$url")
            echo -n "   Fetching $source_name... "

            if curl -s --max-time 30 -A "IranFirewall/$VERSION" "$url" 2>/dev/null | \
               grep -E '^[0-9a-fA-F:]+/[0-9]+' >> "$ipv6_file"; then
                echo -e "${GREEN}✓${NC}"
            else
                echo -e "${RED}✗${NC}"
            fi
        done

        sort -u "$ipv6_file" -o "$ipv6_file"
    fi

    local ipv6_count=$(wc -l < "$ipv6_file" 2>/dev/null || echo 0)

    if [[ $ipv4_count -eq 0 ]]; then
        echo -e "${RED}   ❌ All IPv4 downloads failed!${NC}"
        return 1
    fi

    echo -e "\n   ${GREEN}📊 Total: $ipv4_count IPv4 + $ipv6_count IPv6 ranges${NC}"
    return 0
}

#═══════════════════════════════════════════════════════════════════════════════
# IPSet Management
#═══════════════════════════════════════════════════════════════════════════════

create_ipsets() {
    echo -e "\n${BLUE}📦 Creating IP sets...${NC}"

    # Destroy existing sets (ignore errors)
    ipset destroy "$IPSET_V4" 2>/dev/null
    ipset destroy "$IPSET_V6" 2>/dev/null

    # Create new sets with hash:net type for CIDR support
    ipset create "$IPSET_V4" hash:net family inet hashsize 4096 maxelem 65536
    ipset create "$IPSET_V6" hash:net family inet6 hashsize 1024 maxelem 65536

    # Add DNS servers to IPv4 set
    echo "   Adding DNS servers..."
    for dns in "${DNS_SERVERS_V4[@]}"; do
        ipset add "$IPSET_V4" "$dns/32" 2>/dev/null || true
    done

    # Add Iran IPv4 ranges
    echo "   Adding Iran IPv4 ranges..."
    local count=0
    local total=$(wc -l < /tmp/iran_ipv4.txt)

    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        ipset add "$IPSET_V4" "$ip" 2>/dev/null || true
        ((count++))

        # Progress every 100 entries
        if ((count % 100 == 0)); then
            printf "\r   Progress: %d/%d" "$count" "$total"
        fi
    done < /tmp/iran_ipv4.txt
    echo -e "\r   ${GREEN}✅ Added $count IPv4 ranges${NC}          "

    # Add DNS servers to IPv6 set
    for dns in "${DNS_SERVERS_V6[@]}"; do
        ipset add "$IPSET_V6" "$dns/128" 2>/dev/null || true
    done

    # Add Iran IPv6 ranges
    if [[ -s /tmp/iran_ipv6.txt ]]; then
        echo "   Adding Iran IPv6 ranges..."
        count=0
        total=$(wc -l < /tmp/iran_ipv6.txt)

        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            ipset add "$IPSET_V6" "$ip" 2>/dev/null || true
            ((count++))
        done < /tmp/iran_ipv6.txt
        echo -e "   ${GREEN}✅ Added $count IPv6 ranges${NC}"
    fi

    return 0
}

#═══════════════════════════════════════════════════════════════════════════════
# Firewall Rules Management
#═══════════════════════════════════════════════════════════════════════════════

remove_rules() {
    echo -e "\n${BLUE}🧹 Removing existing rules...${NC}"

    # Remove ALL references to our chain from INPUT (may have multiple for different ports)
    # Keep trying until no more references exist
    while iptables -D INPUT -j "$CHAIN_NAME" 2>/dev/null; do :; done
    while ip6tables -D INPUT -j "$CHAIN_NAME" 2>/dev/null; do :; done

    # Also remove port-specific jumps (in case they reference our chain with port filters)
    # This handles the case where we have: -p tcp --dport 443 -j IRAN_CONDUIT
    for proto in tcp udp; do
        while iptables -D INPUT -p $proto -j "$CHAIN_NAME" 2>/dev/null; do :; done
        while ip6tables -D INPUT -p $proto -j "$CHAIN_NAME" 2>/dev/null; do :; done
    done

    # Flush and delete chains
    iptables -F "$CHAIN_NAME" 2>/dev/null
    iptables -X "$CHAIN_NAME" 2>/dev/null
    ip6tables -F "$CHAIN_NAME" 2>/dev/null
    ip6tables -X "$CHAIN_NAME" 2>/dev/null

    # Remove ipsets (must be done after rules are removed)
    ipset destroy "$IPSET_V4" 2>/dev/null
    ipset destroy "$IPSET_V6" 2>/dev/null

    echo -e "   ${GREEN}✅ Old rules removed${NC}"
}

enable_iran_only() {
    local strict_mode="${1:-false}"

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "${GREEN}🇮🇷 ENABLING IRAN-ONLY MODE${NC}"
    [[ "$strict_mode" == "true" ]] && echo -e "${YELLOW}   [STRICT MODE]${NC}"
    echo "═══════════════════════════════════════════════════════════════"

    # Step 0: Get Conduit ports (CRITICAL - ensures we only affect Conduit)
    CONDUIT_PORTS=()
    if ! get_conduit_ports; then
        echo -e "${RED}❌ Port configuration cancelled${NC}"
        return 1
    fi

    # Step 1: Download IPs
    if ! download_iran_ips "true"; then
        echo -e "${RED}❌ Failed to download Iran IP ranges${NC}"
        return 1
    fi

    # Step 2: Remove existing rules
    remove_rules

    # Step 3: Create ipsets with Iran IPs
    create_ipsets

    # Step 4: Create iptables chains
    echo -e "\n${BLUE}🔥 Creating firewall rules...${NC}"

    # Create custom chains for IPv4 and IPv6
    iptables -N "$CHAIN_NAME" 2>/dev/null || iptables -F "$CHAIN_NAME"
    ip6tables -N "$CHAIN_NAME" 2>/dev/null || ip6tables -F "$CHAIN_NAME"

    # Build port match string for iptables
    local port_match=""
    local port_match_multi=""
    if [[ ${#CONDUIT_PORTS[@]} -gt 0 ]]; then
        if [[ ${#CONDUIT_PORTS[@]} -eq 1 ]]; then
            # Single port or range
            port_match="--dport ${CONDUIT_PORTS[0]}"
        else
            # Multiple ports - use multiport module
            local ports_csv=$(IFS=','; echo "${CONDUIT_PORTS[*]}")
            port_match="-m multiport --dports $ports_csv"
        fi
        echo -e "   ${GREEN}✅ Rules will ONLY affect port(s): ${CONDUIT_PORTS[*]}${NC}"
    else
        echo -e "   ${YELLOW}⚠️  Rules will affect ALL ports (no port filter)${NC}"
    fi

    #───────────────────────────────────────────────────────────────────────────
    # IPv4 RULES (only for Conduit ports)
    #───────────────────────────────────────────────────────────────────────────

    echo "   Creating IPv4 rules..."

    # The chain will ONLY be jumped to for Conduit ports (see ATTACH section below)
    # So all rules in this chain only affect Conduit traffic

    # Allow established/related connections (stateful)
    iptables -A "$CHAIN_NAME" -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Allow loopback
    iptables -A "$CHAIN_NAME" -i lo -j ACCEPT

    # Allow DNS responses (UDP 53) from whitelisted DNS servers
    for dns in "${DNS_SERVERS_V4[@]}"; do
        iptables -A "$CHAIN_NAME" -p udp -s "$dns" --sport 53 -j ACCEPT
        iptables -A "$CHAIN_NAME" -p tcp -s "$dns" --sport 53 -j ACCEPT
    done

    if [[ "$strict_mode" == "true" ]]; then
        # STRICT MODE: Only allow TCP from Iran IPs
        iptables -A "$CHAIN_NAME" -p tcp -m set --match-set "$IPSET_V4" src -j ACCEPT
    else
        # NORMAL MODE: Allow TCP from anywhere (for Psiphon broker visibility)
        iptables -A "$CHAIN_NAME" -p tcp -j ACCEPT
    fi

    # Allow UDP ONLY from Iran IPs (main data tunnel)
    iptables -A "$CHAIN_NAME" -p udp -m set --match-set "$IPSET_V4" src -j ACCEPT

    # EXPLICIT BLOCK: Drop all other UDP (don't rely on policy)
    iptables -A "$CHAIN_NAME" -p udp -j DROP

    # In strict mode, also block non-Iran TCP
    if [[ "$strict_mode" == "true" ]]; then
        iptables -A "$CHAIN_NAME" -p tcp -j DROP
    fi

    # Return for non-matched traffic (let it continue through normal INPUT chain)
    # This is important - we don't DROP everything, just non-Iran UDP
    iptables -A "$CHAIN_NAME" -j RETURN

    #───────────────────────────────────────────────────────────────────────────
    # IPv6 RULES (only for Conduit ports)
    #───────────────────────────────────────────────────────────────────────────

    echo "   Creating IPv6 rules..."

    # Allow established/related connections
    ip6tables -A "$CHAIN_NAME" -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Allow loopback
    ip6tables -A "$CHAIN_NAME" -i lo -j ACCEPT

    # Allow ICMPv6 (needed for IPv6 to work properly)
    ip6tables -A "$CHAIN_NAME" -p ipv6-icmp -j ACCEPT

    # Allow DNS responses from whitelisted IPv6 DNS servers
    for dns in "${DNS_SERVERS_V6[@]}"; do
        ip6tables -A "$CHAIN_NAME" -p udp -s "$dns" --sport 53 -j ACCEPT
        ip6tables -A "$CHAIN_NAME" -p tcp -s "$dns" --sport 53 -j ACCEPT
    done

    if [[ "$strict_mode" == "true" ]]; then
        # STRICT MODE: Only allow TCP from Iran IPv6
        ip6tables -A "$CHAIN_NAME" -p tcp -m set --match-set "$IPSET_V6" src -j ACCEPT
    else
        # NORMAL MODE: Allow TCP from anywhere
        ip6tables -A "$CHAIN_NAME" -p tcp -j ACCEPT
    fi

    # Allow UDP ONLY from Iran IPv6
    ip6tables -A "$CHAIN_NAME" -p udp -m set --match-set "$IPSET_V6" src -j ACCEPT

    # EXPLICIT BLOCK: Drop all other IPv6 UDP
    ip6tables -A "$CHAIN_NAME" -p udp -j DROP

    if [[ "$strict_mode" == "true" ]]; then
        ip6tables -A "$CHAIN_NAME" -p tcp -j DROP
    fi

    # Return for non-matched traffic
    ip6tables -A "$CHAIN_NAME" -j RETURN

    #───────────────────────────────────────────────────────────────────────────
    # ATTACH CHAIN TO INPUT - ONLY FOR CONDUIT PORTS
    # This is the KEY: we only jump to our chain for traffic on Conduit ports
    #───────────────────────────────────────────────────────────────────────────

    echo "   Activating rules (port-specific)..."

    if [[ ${#CONDUIT_PORTS[@]} -gt 0 ]]; then
        # Create rules that jump to our chain ONLY for Conduit ports
        for port in "${CONDUIT_PORTS[@]}"; do
            # Check if port contains colon (range) or is single port
            if [[ "$port" == *":"* ]]; then
                # Port range
                iptables -I INPUT 1 -p udp --dport "$port" -j "$CHAIN_NAME"
                iptables -I INPUT 1 -p tcp --dport "$port" -j "$CHAIN_NAME"
                ip6tables -I INPUT 1 -p udp --dport "$port" -j "$CHAIN_NAME"
                ip6tables -I INPUT 1 -p tcp --dport "$port" -j "$CHAIN_NAME"
            else
                # Single port
                iptables -I INPUT 1 -p udp --dport "$port" -j "$CHAIN_NAME"
                iptables -I INPUT 1 -p tcp --dport "$port" -j "$CHAIN_NAME"
                ip6tables -I INPUT 1 -p udp --dport "$port" -j "$CHAIN_NAME"
                ip6tables -I INPUT 1 -p tcp --dport "$port" -j "$CHAIN_NAME"
            fi
        done
        echo -e "   ${GREEN}✅ Rules attached to INPUT for ports: ${CONDUIT_PORTS[*]}${NC}"
    else
        # No port filter - apply to all (user confirmed this)
        iptables -I INPUT 1 -j "$CHAIN_NAME"
        ip6tables -I INPUT 1 -j "$CHAIN_NAME"
        echo -e "   ${YELLOW}⚠️  Rules attached to INPUT for ALL ports${NC}"
    fi

    #───────────────────────────────────────────────────────────────────────────
    # SUMMARY
    #───────────────────────────────────────────────────────────────────────────

    local ipv4_count=$(wc -l < /tmp/iran_ipv4.txt)
    local ipv6_count=$(wc -l < /tmp/iran_ipv6.txt 2>/dev/null || echo 0)
    local rule_count=$(iptables -L "$CHAIN_NAME" -n | wc -l)
    local ports_str="${CONDUIT_PORTS[*]:-ALL}"

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "${GREEN}✅ IRAN-ONLY MODE ENABLED!${NC}"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo -e "   ${CYAN}🎯 Affected port(s): ${ports_str}${NC}"
    echo "   📊 Chain rules: $rule_count"
    echo "   🇮🇷 Iran IPv4: $ipv4_count ranges"
    echo "   🇮🇷 Iran IPv6: $ipv6_count ranges"

    if [[ "$strict_mode" == "true" ]]; then
        echo ""
        echo -e "   ${YELLOW}⚠️  STRICT MODE: TCP also restricted to Iran${NC}"
        echo "      (Psiphon broker visibility may be affected)"
    else
        echo ""
        echo "   🌍 TCP: Global (for broker visibility)"
        echo "   🇮🇷 UDP: Iran only"
    fi

    echo ""
    echo -e "   ${GREEN}✅ YOUR OTHER SERVICES ARE NOT AFFECTED!${NC}"
    if [[ ${#CONDUIT_PORTS[@]} -gt 0 ]]; then
        echo "   Only traffic on port(s) ${ports_str} is filtered."
    fi

    # Save configuration
    cat > "$CONFIG_FILE" << EOF
{
    "last_update": "$(date '+%Y-%m-%d %H:%M:%S')",
    "strict_mode": $strict_mode,
    "ipv4_count": $ipv4_count,
    "ipv6_count": $ipv6_count,
    "ports": "${ports_str}",
    "version": "$VERSION"
}
EOF

    log "Iran-only mode enabled. Ports: ${ports_str}, IPv4: $ipv4_count, IPv6: $ipv6_count, Strict: $strict_mode"

    echo ""
    echo -e "   ${GREEN}✅ Rules are now active!${NC}"
    echo "   🇮🇷 Only Iranian users can connect to Conduit!"

    return 0
}

disable_iran_only() {
    echo ""
    echo -e "${BLUE}🔓 Disabling Iran-only mode...${NC}"
    echo ""

    remove_rules

    echo -e "${GREEN}✅ Iran-only mode DISABLED${NC}"
    echo "   System now accepts connections from all countries."

    log "Iran-only mode disabled"
}

show_status() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "${CYAN}📊 CURRENT STATUS${NC}"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    # Check if chain exists
    if iptables -L "$CHAIN_NAME" -n &>/dev/null; then
        echo -e "${GREEN}✅ IRAN-ONLY MODE ENABLED${NC}"
        echo ""

        # Count rules
        local rule_count=$(iptables -L "$CHAIN_NAME" -n 2>/dev/null | grep -c '^')
        local rule_count6=$(ip6tables -L "$CHAIN_NAME" -n 2>/dev/null | grep -c '^')

        echo "   📋 IPv4 chain rules: $rule_count"
        echo "   📋 IPv6 chain rules: $rule_count6"

        # Check ipset
        if ipset list "$IPSET_V4" &>/dev/null; then
            local ipv4_entries=$(ipset list "$IPSET_V4" | grep -c '^[0-9]')
            echo "   🇮🇷 IPv4 ranges in set: $ipv4_entries"
        fi

        if ipset list "$IPSET_V6" &>/dev/null; then
            local ipv6_entries=$(ipset list "$IPSET_V6" | grep -c '^[0-9a-f]')
            echo "   🇮🇷 IPv6 ranges in set: $ipv6_entries"
        fi

        # Show config if exists
        if [[ -f "$CONFIG_FILE" ]]; then
            echo ""
            local last_update=$(grep -o '"last_update": "[^"]*"' "$CONFIG_FILE" | cut -d'"' -f4)
            local strict=$(grep -o '"strict_mode": [^,}]*' "$CONFIG_FILE" | cut -d':' -f2 | tr -d ' ')
            local ports=$(grep -o '"ports": "[^"]*"' "$CONFIG_FILE" | cut -d'"' -f4)

            echo -e "   ${CYAN}🎯 Affected port(s): ${ports:-unknown}${NC}"
            echo "   🕒 Last updated: $last_update"
            if [[ "$strict" == "true" ]]; then
                echo -e "   ${YELLOW}⚠️  Mode: STRICT (TCP restricted)${NC}"
            else
                echo "   🌍 Mode: Normal (TCP global)"
            fi
        fi

        # Show INPUT chain rules that reference our chain
        echo ""
        echo "   📌 INPUT rules pointing to $CHAIN_NAME:"
        iptables -L INPUT -n --line-numbers 2>/dev/null | grep "$CHAIN_NAME" | while read line; do
            echo "      $line"
        done
    else
        echo -e "${YELLOW}❌ IRAN-ONLY MODE DISABLED${NC}"
        echo "   No firewall rules are active."
    fi

    echo ""
}

save_rules() {
    echo -e "\n${BLUE}💾 Saving rules for persistence...${NC}"

    # Check for iptables-save
    if command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
        iptables-save > /etc/iptables.rules 2>/dev/null || \
        echo -e "${YELLOW}⚠️  Could not save iptables rules to standard location${NC}"
    fi

    if command -v ip6tables-save &>/dev/null; then
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || \
        ip6tables-save > /etc/ip6tables.rules 2>/dev/null || true
    fi

    # Save ipsets
    if command -v ipset &>/dev/null; then
        ipset save > /etc/ipset.rules 2>/dev/null || \
        ipset save > /etc/ipset.conf 2>/dev/null || true
    fi

    echo -e "${GREEN}✅ Rules saved${NC}"
    echo ""
    echo "   To restore on boot, add to /etc/rc.local or use:"
    echo "   - Debian/Ubuntu: apt install iptables-persistent"
    echo "   - RHEL/CentOS: service iptables save"
    echo "   - Systemd: Create a service unit"
}

show_help() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                    HELP - Iran-Only Firewall v$VERSION               ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "WHAT THIS DOES:"
    echo "  • Creates iptables/ip6tables rules that ONLY allow Iranian IPs"
    echo "    to connect via UDP (main data tunnel) on Conduit's port(s)."
    echo "  • Uses ipset for efficient IP matching (hash tables)."
    echo "  • Allows TCP globally so Psiphon brokers can see your node."
    echo ""
    echo "IMPORTANT - PORT-SPECIFIC FILTERING:"
    echo "  • Rules ONLY affect traffic on the port(s) you specify."
    echo "  • Your other services (SSH, web server, etc.) are NOT affected."
    echo "  • The script will try to auto-detect Conduit's listening ports."
    echo "  • You can also manually specify ports (e.g., 443, 8080, 8000:9000)."
    echo ""
    echo "HOW IT WORKS (Rule Priority):"
    echo "  1. Traffic arrives on Conduit port → jump to IRAN_CONDUIT chain"
    echo "  2. ACCEPT established/related connections"
    echo "  3. ACCEPT DNS from whitelisted servers"
    echo "  4. ACCEPT TCP globally (or Iran-only in strict mode)"
    echo "  5. ACCEPT UDP from Iran IP ranges"
    echo "  6. DROP all other UDP (explicit)"
    echo "  7. Traffic on OTHER ports → unaffected, normal processing"
    echo ""
    echo "MODES:"
    echo "  • Normal Mode: TCP global, UDP Iran-only"
    echo "    - Best for: Most users (ensures broker visibility)"
    echo ""
    echo "  • Strict Mode: TCP Iran-only, UDP Iran-only"
    echo "    - Best for: Maximum restriction"
    echo ""
    echo "USAGE:"
    echo "  sudo $0                  Interactive menu"
    echo "  sudo $0 enable           Enable normal mode"
    echo "  sudo $0 enable-strict    Enable strict mode"
    echo "  sudo $0 disable          Disable Iran-only mode"
    echo "  sudo $0 status           Show current status"
    echo "  sudo $0 save             Save rules for persistence"
    echo "  sudo $0 help             Show this help"
    echo ""
    echo "REQUIREMENTS:"
    echo "  • Linux with iptables, ipset, and ss (iproute2)"
    echo "  • Root privileges"
    echo "  • curl for downloading IP ranges"
    echo ""
    echo "LOG FILE: $LOG_FILE"
    echo ""
}

#═══════════════════════════════════════════════════════════════════════════════
# Interactive Menu
#═══════════════════════════════════════════════════════════════════════════════

show_menu() {
    while true; do
        print_header
        echo "─────────────────────────────────────────────────────"
        echo "  MAIN MENU"
        echo "─────────────────────────────────────────────────────"
        echo "  1. 🟢 Enable Iran-only mode (Normal)"
        echo "  2. 🔒 Enable Iran-only mode (Strict)"
        echo "  3. 🔴 Disable Iran-only mode"
        echo "  4. 📊 Check status"
        echo "  5. 💾 Save rules (persistence)"
        echo "  6. ❓ Help"
        echo "  0. 🚪 Exit"
        echo "─────────────────────────────────────────────────────"
        echo "  Normal: TCP global, UDP Iran-only"
        echo "  Strict: TCP+UDP Iran-only"
        echo ""
        echo -e "  ${CYAN}✅ Only affects Conduit's port(s) - other services safe${NC}"
        echo "─────────────────────────────────────────────────────"
        echo ""
        read -p "  Enter choice: " choice

        case "$choice" in
            1)
                enable_iran_only "false"
                read -p "   Press Enter to continue..."
                ;;
            2)
                echo ""
                echo -e "${YELLOW}⚠️  STRICT MODE: Restricts both TCP and UDP to Iran only.${NC}"
                echo "   This may cause Psiphon brokers to stop seeing your node."
                read -p "   Enable Strict mode anyway? (y/n): " confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    enable_iran_only "true"
                fi
                read -p "   Press Enter to continue..."
                ;;
            3)
                disable_iran_only
                read -p "   Press Enter to continue..."
                ;;
            4)
                show_status
                read -p "   Press Enter to continue..."
                ;;
            5)
                save_rules
                read -p "   Press Enter to continue..."
                ;;
            6)
                show_help
                read -p "   Press Enter to continue..."
                ;;
            0)
                clear
                echo ""
                echo "👋 Thank you for helping Iran!"
                echo "   Share this tool to help more people."
                echo ""
                log "=== Iran Firewall exited ==="
                exit 0
                ;;
            *)
                echo "   Invalid choice. Enter 0-6."
                sleep 1
                ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════════════
# Main Entry Point
#═══════════════════════════════════════════════════════════════════════════════

main() {
    check_root
    check_dependencies

    log "=== Iran Firewall v$VERSION started ==="

    # Handle command line arguments
    case "${1:-}" in
        enable)
            enable_iran_only "false"
            ;;
        enable-strict)
            enable_iran_only "true"
            ;;
        disable)
            disable_iran_only
            ;;
        status)
            show_status
            ;;
        save)
            save_rules
            ;;
        help|--help|-h)
            show_help
            ;;
        "")
            # No arguments - show interactive menu
            show_menu
            ;;
        *)
            echo "Unknown command: $1"
            echo "Use '$0 help' for usage information."
            exit 1
            ;;
    esac
}

# Run main
main "$@"
