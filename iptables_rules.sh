#!/bin/bash
#
# NexusRoute - iptables TPROXY rules
# Per-user transparent proxy with MAC-IP binding and Kill Switch
#
# Architecture - Two Layers:
#
#   Layer 1: Ubuntu Kernel (iptables/netfilter)
#     - FORWARD DROP:          LAN 设备无法直连外网
#     - IPv6 disabled:         防止 IPv6 绕过
#     - Anti-spoofing:         MAC-IP 绑定，防冒用
#
#   Layer 2: Proxy Program (per-user mangle rules)
#     - TPROXY TCP/UDP:        合法流量送入 Xray 代理
#     - DROP ICMP:             禁止 ping（防泄露真实 IP）
#     - DROP other protocols:  禁止 GRE/SCTP/ESP 等
#     - Xray crash = 断网:     TPROXY 无 socket 时内核自动丢包
#
# Usage:
#   setup                                    - Build all rules from database
#   clear                                    - Remove all rules
#   show                                     - Display current rules
#   add-user <id> <ip> <mac> <port> <mark>   - Add single user rules
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Root check
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root"
    exit 1
fi

# Read config (written by install.sh)
CONFIG_FILE="/opt/nexusroute/config.json"
LAN_IF="eth1"
WAN_IF="eth0"
LAN_IP="192.168.100.1"

if [ -f "$CONFIG_FILE" ]; then
    LAN_IF=$(grep -o '"lan_if"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*: *"//;s/".*//')
    WAN_IF=$(grep -o '"wan_if"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*: *"//;s/".*//')
    LAN_IP=$(grep -o '"lan_ip"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*: *"//;s/".*//')
fi

LAN_IF=${LAN_IF:-eth1}
WAN_IF=${WAN_IF:-eth0}
LAN_IP=${LAN_IP:-192.168.100.1}

log_info "Interfaces: LAN=$LAN_IF  WAN=$WAN_IF  Gateway=$LAN_IP"

# ==================== Rules ====================

clear_rules() {
    log_info "Clearing existing iptables rules..."

    # Set ACCEPT policies FIRST to prevent lockout during flush
    # (if UFW or other firewall set INPUT policy to DROP)
    iptables -P INPUT ACCEPT 2>/dev/null || true
    iptables -P FORWARD ACCEPT 2>/dev/null || true
    iptables -P OUTPUT ACCEPT 2>/dev/null || true
    ip6tables -P INPUT ACCEPT 2>/dev/null || true
    ip6tables -P FORWARD ACCEPT 2>/dev/null || true
    ip6tables -P OUTPUT ACCEPT 2>/dev/null || true

    # Now safe to flush all chains
    iptables -F 2>/dev/null || true
    iptables -X 2>/dev/null || true
    iptables -t mangle -F 2>/dev/null || true
    iptables -t mangle -X 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    iptables -t nat -X 2>/dev/null || true
    ip6tables -F 2>/dev/null || true
    ip6tables -X 2>/dev/null || true

    # Clean up policy routing
    ip rule show | grep "fwmark" | while read -r line; do
        prio=$(echo "$line" | awk '{print $1}' | tr -d ':')
        ip rule del prio "$prio" 2>/dev/null || true
    done

    for i in $(seq 100 399); do
        # Skip system routing tables: 253(default) 254(main) 255(local)
        [ "$i" = "253" ] || [ "$i" = "254" ] || [ "$i" = "255" ] && continue
        ip route flush table $i 2>/dev/null || true
    done

    # Re-enable IPv6
    sysctl -w net.ipv6.conf.$LAN_IF.disable_ipv6=0 2>/dev/null || true

    log_info "Rules cleared"
}

setup_base_rules() {
    log_info "Setting base firewall rules..."

    # ==================== Default Policies ====================
    # INPUT/OUTPUT ACCEPT: Ubuntu 自身正常使用（apt/curl/代理出站等全走WAN）
    # FORWARD DROP: Kill Switch 核心，LAN 设备不能直连外网
    iptables -P INPUT ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -P FORWARD DROP

    # ==================== FORWARD Chain (Kill Switch) ====================
    # FORWARD 默认策略 DROP 已阻断所有 LAN 转发（TCP/UDP/ICMP/GRE/SCTP/ESP 全部无法直连外网）
    # 显式阻断 ICMP 仅作为双重保险（防止策略意外被改时 ping 泄露真实 IP）
    iptables -A FORWARD -i $LAN_IF -p icmp -m comment --comment "Kill Switch: Block ICMP" -j DROP

    # ==================== IPv6 Kill Switch ====================
    # 三重封杀 IPv6：sysctl + FORWARD DROP + LAN 接口全阻断
    # 目的：防止 LAN 设备通过 IPv6 绕过代理

    # 1. sysctl: 内核层面禁用 LAN 接口的 IPv6
    sysctl -w net.ipv6.conf.$LAN_IF.disable_ipv6=1 2>/dev/null || true
    sysctl -w net.ipv6.conf.$LAN_IF.forwarding=0 2>/dev/null || true

    # 2. ip6tables FORWARD DROP: 即使 IPv6 没被完全禁用，也阻断所有转发
    #    LAN 设备的 IPv6 流量永远无法通过网关转发到外网
    # 3. LAN 接口 INPUT DROP: 拒绝 LAN 侧的 IPv6 连接到网关自身
    # 4. Ubuntu 自身 OUTPUT ACCEPT: 不阻断 WAN 接口的 IPv6（apt/DNS 等可能需要）
    ip6tables -P INPUT ACCEPT 2>/dev/null || true
    ip6tables -P FORWARD DROP 2>/dev/null || true
    ip6tables -P OUTPUT ACCEPT 2>/dev/null || true
    ip6tables -F 2>/dev/null || true
    ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
    ip6tables -A INPUT -i $LAN_IF -j DROP 2>/dev/null || true
    ip6tables -A FORWARD -i $LAN_IF -j DROP 2>/dev/null || true
    ip6tables -A FORWARD -o $LAN_IF -j DROP 2>/dev/null || true

    log_info "Base rules set (Kill Switch active: FORWARD DROP + IPv6 disabled)"
}

add_user_rules() {
    local USER_ID=$1
    local USER_IP=$2
    local USER_MAC=$3
    local XRAY_PORT=$4
    local MARK=$5

    log_info "Adding rules: user${USER_ID} (${USER_IP}, port=${XRAY_PORT})"

    # ==================== PREROUTING mangle (per-user) ====================

    # 防线5: 反IP欺骗 - 冒用此 IP 但 MAC 不匹配则 DROP
    iptables -t mangle -A PREROUTING -i $LAN_IF \
        -s ${USER_IP} \
        -m mac ! --mac-source ${USER_MAC} \
        -m comment --comment "user${USER_ID}: Anti-spoofing" \
        -j DROP

    # ==================== 内网流量豁免（关键！） ====================
    # 不把访问内网的流量送进代理，否则网关 Web/DNS/DHCP 全部瘫痪
    # 包括：LAN 设备访问网关自身、跨网段管理通道、广播包
    iptables -t mangle -A PREROUTING -i $LAN_IF \
        -s ${USER_IP} -d 192.168.0.0/16 \
        -m comment --comment "user${USER_ID}: Bypass LAN" \
        -j RETURN
    iptables -t mangle -A PREROUTING -i $LAN_IF \
        -s ${USER_IP} -d 10.0.0.0/8 \
        -m comment --comment "user${USER_ID}: Bypass private" \
        -j RETURN
    iptables -t mangle -A PREROUTING -i $LAN_IF \
        -s ${USER_IP} -d 172.16.0.0/12 \
        -m comment --comment "user${USER_ID}: Bypass private" \
        -j RETURN
    iptables -t mangle -A PREROUTING -i $LAN_IF \
        -s ${USER_IP} -d 255.255.255.255/32 \
        -m comment --comment "user${USER_ID}: Bypass broadcast" \
        -j RETURN

    # 防线3: 阻断 ICMP（防止通过 ping 泄露真实 IP）
    iptables -t mangle -A PREROUTING -i $LAN_IF \
        -s ${USER_IP} -p icmp \
        -m comment --comment "user${USER_ID}: Block ICMP" \
        -j DROP

    # ==================== NAT REDIRECT (TCP 透明代理) ====================
    # 使用 REDIRECT 替代 TPROXY（不需要 IP_TRANSPARENT，兼容性更好）
    # DNS 由 dnsmasq 单独处理，UDP 流量由 FORWARD DROP 阻断（Kill Switch）
    iptables -t nat -A PREROUTING -i $LAN_IF \
        -s ${USER_IP} -p tcp \
        -m comment --comment "user${USER_ID}: REDIRECT TCP" \
        -j REDIRECT --to-port ${XRAY_PORT}

    log_info "user${USER_ID} rules added"
}

setup_user_rules() {
    log_info "Loading users from database..."

    local DB_PATH="/opt/nexusroute/db.sqlite"
    if [ ! -f "$DB_PATH" ]; then
        log_warn "Database not found, skipping user rules"
        return
    fi

    local USERS=$(sqlite3 "$DB_PATH" "SELECT id, ip_address, mac_address, xray_port, iptables_mark FROM users WHERE enabled = 1;" 2>/dev/null)
    if [ -z "$USERS" ]; then
        log_warn "No enabled users found"
        return
    fi

    while IFS='|' read -r USER_ID USER_IP USER_MAC XRAY_PORT MARK; do
        add_user_rules "$USER_ID" "$USER_IP" "$USER_MAC" "$XRAY_PORT" "$MARK"
    done <<< "$USERS"

    log_info "All user rules loaded"
}

save_rules() {
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save 2>/dev/null && log_info "Rules saved (netfilter-persistent)"
    elif command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null && log_info "Rules saved to /etc/iptables/rules.v4"
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    fi
}

show_rules() {
    echo ""
    echo "=== IPv4 FORWARD (policy DROP - Kill Switch) ==="
    iptables -L FORWARD -n -v --line-numbers 2>/dev/null
    echo ""
    echo "=== IPv4 Mangle PREROUTING (LAN=$LAN_IF) ==="
    iptables -t mangle -L PREROUTING -n -v --line-numbers 2>/dev/null
    echo ""
    echo "=== IPv4 NAT PREROUTING (REDIRECT) ==="
    iptables -t nat -L PREROUTING -n -v --line-numbers 2>/dev/null
    echo ""
    echo "=== IPv6 (should be locked down) ==="
    ip6tables -L -n -v 2>/dev/null || echo "(ip6tables not available)"
    echo ""
    echo "=== IPv6 on $LAN_IF ==="
    sysctl net.ipv6.conf.$LAN_IF.disable_ipv6 2>/dev/null || echo "(not available)"
}

# ==================== Main ====================

case "${1:-setup}" in
    setup)
        log_info "Setting up all iptables rules..."
        clear_rules
        setup_base_rules
        setup_user_rules
        save_rules
        log_info "Done!"
        show_rules
        ;;
    clear)
        clear_rules
        save_rules
        log_info "Rules cleared (firewall open, IPv6 re-enabled)"
        ;;
    show)
        show_rules
        ;;
    add-user)
        if [ $# -ne 6 ]; then
            log_error "Usage: $0 add-user <user_id> <ip> <mac> <port> <mark>"
            exit 1
        fi
        add_user_rules "$2" "$3" "$4" "$5" "$6"
        save_rules
        ;;
    *)
        echo "Usage: $0 {setup|clear|show|add-user}"
        echo ""
        echo "  setup                        - Build all rules from database"
        echo "  clear                        - Remove all rules"
        echo "  show                         - Display current rules"
        echo "  add-user <id> <ip> <mac> <port> <mark>"
        echo "                               - Add single user rules"
        exit 1
        ;;
esac
