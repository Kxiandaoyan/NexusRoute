#!/bin/bash
#
# NexusRoute - iptables TPROXY 规则脚本
# 功能：为每个用户创建独立的透明代理规则，实现 MAC-IP 双重绑定和防漏油机制
#

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    log_error "请使用 root 权限运行此脚本"
    exit 1
fi

# 清空现有规则
clear_rules() {
    log_info "清空现有 iptables 规则..."

    # 清空 mangle 表
    iptables -t mangle -F
    iptables -t mangle -X

    # 清空 filter 表
    iptables -F
    iptables -X

    # 清空路由规则（保留默认规则）
    ip rule del fwmark 0x1 table 100 2>/dev/null || true
    ip rule del fwmark 0x2 table 101 2>/dev/null || true
    ip rule del fwmark 0x3 table 102 2>/dev/null || true
    ip rule del fwmark 0x4 table 103 2>/dev/null || true
    ip rule del fwmark 0x5 table 104 2>/dev/null || true

    # 清空路由表
    ip route flush table 100 2>/dev/null || true
    ip route flush table 101 2>/dev/null || true
    ip route flush table 102 2>/dev/null || true
    ip route flush table 103 2>/dev/null || true
    ip route flush table 104 2>/dev/null || true

    log_info "规则清空完成"
}

# 设置基础规则
setup_base_rules() {
    log_info "设置基础防火墙规则..."

    # 设置默认策略（Kill Switch 核心）
    iptables -P INPUT ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -P FORWARD DROP  # 关键：默认拒绝转发，防止漏油

    # 允许本地回环
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT

    # 允许已建立的连接
    iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A OUTPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

    # 允许 eth1 的 DHCP 和 DNS 请求（到网关本身）
    iptables -A INPUT -i eth1 -p udp --dport 67 -j ACCEPT  # DHCP
    iptables -A INPUT -i eth1 -p udp --dport 53 -j ACCEPT  # DNS
    iptables -A INPUT -i eth1 -p tcp --dport 53 -j ACCEPT  # DNS over TCP

    # 允许 eth1 的 HTTP 访问（Web 面板）
    iptables -A INPUT -i eth1 -p tcp --dport 80 -j ACCEPT

    # 允许 SSH（可选，根据需要调整）
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT

    # 明确阻止 eth1 的 ICMP 转发（Kill Switch - 双重保险）
    iptables -A FORWARD -i eth1 -p icmp -j DROP -m comment --comment "Kill Switch: Block ICMP forwarding"

    # 明确阻止 eth1 的其他协议转发（Kill Switch - 只允许 TCP/UDP）
    iptables -A FORWARD -i eth1 ! -p tcp ! -p udp -j DROP -m comment --comment "Kill Switch: Block non-TCP/UDP forwarding"

    log_info "基础规则设置完成（含 Kill Switch 保护）"
}

# 为单个用户添加规则
add_user_rules() {
    local USER_ID=$1
    local USER_IP=$2
    local USER_MAC=$3
    local XRAY_PORT=$4
    local MARK=$5
    local TABLE_ID=$((100 + USER_ID - 1))

    log_info "添加用户规则: user${USER_ID} (${USER_IP}, ${USER_MAC})"

    # 1. 创建路由表
    if ! ip route show table ${TABLE_ID} | grep -q "local 0.0.0.0/0"; then
        ip rule add fwmark 0x${MARK} table ${TABLE_ID}
        ip route add local 0.0.0.0/0 dev lo table ${TABLE_ID}
    fi

    # 2. 防止 IP 欺骗：如果 IP 和 MAC 不匹配，直接 DROP
    iptables -t mangle -A PREROUTING -i eth1 \
        -s ${USER_IP} \
        -m mac ! --mac-source ${USER_MAC} \
        -j DROP \
        -m comment --comment "user${USER_ID}: Anti-spoofing"

    # 3. 为匹配的流量打标记
    iptables -t mangle -A PREROUTING -i eth1 \
        -s ${USER_IP} \
        -m mac --mac-source ${USER_MAC} \
        -j MARK --set-mark 0x${MARK} \
        -m comment --comment "user${USER_ID}: Mark traffic"

    # 4. TPROXY 劫持 TCP 流量
    iptables -t mangle -A PREROUTING -i eth1 \
        -p tcp \
        -m mark --mark 0x${MARK} \
        -j TPROXY --on-port ${XRAY_PORT} --tproxy-mark 0x${MARK} \
        -m comment --comment "user${USER_ID}: TPROXY TCP"

    # 5. TPROXY 劫持 UDP 流量
    iptables -t mangle -A PREROUTING -i eth1 \
        -p udp \
        -m mark --mark 0x${MARK} \
        ! --dport 67 \
        ! --dport 68 \
        -j TPROXY --on-port ${XRAY_PORT} --tproxy-mark 0x${MARK} \
        -m comment --comment "user${USER_ID}: TPROXY UDP"

    # 6. 明确阻止 ICMP 流量（Kill Switch - 防止 IP 泄露）
    iptables -t mangle -A PREROUTING -i eth1 \
        -s ${USER_IP} \
        -p icmp \
        -j DROP \
        -m comment --comment "user${USER_ID}: Block ICMP (Kill Switch)"

    # 7. 明确阻止其他协议（Kill Switch - 只允许 TCP/UDP）
    iptables -t mangle -A PREROUTING -i eth1 \
        -s ${USER_IP} \
        ! -p tcp \
        ! -p udp \
        ! -p icmp \
        -j DROP \
        -m comment --comment "user${USER_ID}: Block other protocols (Kill Switch)"

    log_info "用户 user${USER_ID} 规则添加完成（含 Kill Switch 保护）"
}

# 从数据库读取用户信息并添加规则
setup_user_rules() {
    log_info "从数据库读取用户信息..."

    local DB_PATH="/opt/nexusroute/db.sqlite"

    if [ ! -f "$DB_PATH" ]; then
        log_warn "数据库文件不存在，跳过用户规则设置"
        return
    fi

    # 读取所有启用的用户
    local USERS=$(sqlite3 "$DB_PATH" "SELECT id, ip_address, mac_address, xray_port, iptables_mark FROM users WHERE enabled = 1;")

    if [ -z "$USERS" ]; then
        log_warn "未找到启用的用户"
        return
    fi

    # 逐行处理
    while IFS='|' read -r USER_ID USER_IP USER_MAC XRAY_PORT MARK; do
        add_user_rules "$USER_ID" "$USER_IP" "$USER_MAC" "$XRAY_PORT" "$MARK"
    done <<< "$USERS"

    log_info "所有用户规则设置完成"
}

# 保存规则
save_rules() {
    log_info "保存 iptables 规则..."

    # 保存到 iptables-persistent
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save
        log_info "规则已保存到 /etc/iptables/rules.v4"
    elif command -v iptables-save &> /dev/null; then
        iptables-save > /etc/iptables/rules.v4
        log_info "规则已保存到 /etc/iptables/rules.v4"
    else
        log_warn "未找到 iptables-save 命令，规则未持久化"
    fi
}

# 显示当前规则
show_rules() {
    log_info "当前 iptables 规则："
    echo ""
    echo "=== Mangle 表 PREROUTING 链 ==="
    iptables -t mangle -L PREROUTING -n -v --line-numbers
    echo ""
    echo "=== Filter 表 FORWARD 链 ==="
    iptables -L FORWARD -n -v --line-numbers
    echo ""
    echo "=== 路由规则 ==="
    ip rule show
    echo ""
    echo "=== 路由表 ==="
    for i in {100..104}; do
        if ip route show table $i 2>/dev/null | grep -q .; then
            echo "Table $i:"
            ip route show table $i
        fi
    done
}

# 主函数
main() {
    case "${1:-setup}" in
        setup)
            log_info "开始设置 iptables 规则..."
            clear_rules
            setup_base_rules
            setup_user_rules
            save_rules
            log_info "iptables 规则设置完成！"
            echo ""
            show_rules
            ;;
        clear)
            clear_rules
            save_rules
            log_info "iptables 规则已清空"
            ;;
        show)
            show_rules
            ;;
        add-user)
            if [ $# -ne 5 ]; then
                log_error "用法: $0 add-user <user_id> <ip> <mac> <port>"
                exit 1
            fi
            add_user_rules "$2" "$3" "$4" "$5" "$2"
            save_rules
            ;;
        *)
            echo "用法: $0 {setup|clear|show|add-user}"
            echo ""
            echo "  setup      - 设置所有规则（从数据库读取）"
            echo "  clear      - 清空所有规则"
            echo "  show       - 显示当前规则"
            echo "  add-user   - 添加单个用户规则"
            echo ""
            exit 1
            ;;
    esac
}

main "$@"
