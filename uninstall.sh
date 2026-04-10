#!/bin/bash
#
# NexusRoute - Uninstall Script
# Removes all services, rules, and configurations
#

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root (sudo ./uninstall.sh)"
    exit 1
fi

INSTALL_DIR="/opt/nexusroute"

echo ""
echo -e "${RED}============================================"
echo "  NexusRoute Uninstall"
echo -e "============================================${NC}"
echo ""
echo "  This will remove:"
echo "  - All Xray user services"
echo "  - NexusRoute service"
echo "  - dnsmasq custom config"
echo "  - All iptables rules (firewall open)"
echo "  - Policy routing rules"
echo "  - Netplan LAN config"
echo "  - Installation directory ($INSTALL_DIR)"
echo ""
echo "  Database will be backed up to /opt/"
echo ""

read -p "Continue? (y/N): " confirm
[ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && echo "Cancelled." && exit 0

# ==================== Step 1: Stop Services ====================
echo ""
log_info "Step 1: Stopping services..."

# Stop all xray user services
for svc in $(systemctl list-units --type=service --all 2>/dev/null | grep -oP 'xray-user\d+'); do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service"
    log_info "Stopped $svc"
done

# Stop xray services (new naming: xray-userN)
for svc in $(systemctl list-units --type=service --all 2>/dev/null | grep -oP 'xray-user\d+'); do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service"
done

systemctl stop nexusroute 2>/dev/null || true
systemctl disable nexusroute 2>/dev/null || true
rm -f /etc/systemd/system/nexusroute.service

# Stop our custom dnsmasq service and restore original
systemctl stop dnsmasq 2>/dev/null || true
systemctl disable dnsmasq 2>/dev/null || true
rm -f /etc/systemd/system/dnsmasq.service
rm -rf /etc/systemd/system/dnsmasq.service.d

systemctl daemon-reload
log_info "All services stopped"

# ==================== Step 2: Clear iptables ====================
echo ""
log_info "Step 2: Clearing iptables rules..."

# Set ACCEPT policies first (prevent lockout)
iptables -P INPUT ACCEPT 2>/dev/null || true
iptables -P FORWARD ACCEPT 2>/dev/null || true
iptables -P OUTPUT ACCEPT 2>/dev/null || true
ip6tables -P INPUT ACCEPT 2>/dev/null || true
ip6tables -P FORWARD ACCEPT 2>/dev/null || true
ip6tables -P OUTPUT ACCEPT 2>/dev/null || true

# Flush all rules
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
    [ "$i" = "253" ] || [ "$i" = "254" ] || [ "$i" = "255" ] && continue
    ip route flush table $i 2>/dev/null || true
done

# Save cleared rules
if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save 2>/dev/null || true
fi

log_info "iptables rules cleared (firewall open)"

# ==================== Step 3: Restore DNS ====================
echo ""
log_info "Step 3: Restoring system DNS..."

# Re-enable systemd-resolved stub listener
sed -i 's/^DNSStubListener=.*/DNSStubListener=yes/' /etc/systemd/resolved.conf
sed -i 's/^#DNSStubListener=yes/DNSStubListener=yes/' /etc/systemd/resolved.conf
systemctl unmask systemd-resolved 2>/dev/null || true
systemctl enable systemd-resolved 2>/dev/null || true
systemctl restart systemd-resolved 2>/dev/null || true

# Restore resolv.conf symlink
rm -f /etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true

log_info "System DNS restored (systemd-resolved)"

# ==================== Step 4: Restore dnsmasq ====================
echo ""
log_info "Step 4: Restoring dnsmasq to default..."

rm -f /etc/dnsmasq.d/static-hosts.conf
# Remove our custom config (package manager will restore default on reinstall)
rm -f /etc/dnsmasq.conf
# Reinstall dnsmasq to get default config back
apt-get install --reinstall -y -q dnsmasq 2>/dev/null || true

log_info "dnsmasq restored to default"

# ==================== Step 5: Remove Netplan LAN Config ====================
echo ""
log_info "Step 5: Removing LAN network config..."

rm -f /etc/netplan/99-nexusroute.yaml
# Don't apply netplan here - let user reboot or apply manually
log_warn "LAN interface config removed. Run 'netplan apply' or reboot to take effect."

# ==================== Step 6: Backup Database & Remove Files ====================
echo ""
log_info "Step 6: Removing installation files..."

# Backup database
if [ -f "$INSTALL_DIR/db.sqlite" ]; then
    BACKUP="/opt/nexusroute_db_backup_$(date +%Y%m%d_%H%M%S).sqlite"
    cp "$INSTALL_DIR/db.sqlite" "$BACKUP"
    log_info "Database backed up to $BACKUP"
fi

# Remove Xray configs
rm -rf /usr/local/etc/xray/config-user*.json

# Remove installation directory
rm -rf "$INSTALL_DIR"
log_info "Installation directory removed"

# ==================== Step 7: Optional Cleanup ====================
echo ""
log_warn "Optional: The following are NOT removed (may be needed by system):"
echo "  - Xray binary: /usr/local/bin/xray"
echo "  - Node.js and npm"
echo "  - dnsmasq package"
echo "  - iptables-persistent package"
echo ""
read -p "Remove Xray binary? (y/N): " rm_xray
if [ "$rm_xray" = "y" ] || [ "$rm_xray" = "Y" ]; then
    rm -f /usr/local/bin/xray
    rm -rf /usr/local/etc/xray
    log_info "Xray removed"
fi

# Re-enable UFW if it was installed
if command -v ufw &>/dev/null; then
    echo ""
    read -p "Enable UFW firewall? (y/N): " enable_ufw
    if [ "$enable_ufw" = "y" ] || [ "$enable_ufw" = "Y" ]; then
        ufw enable
        log_info "UFW enabled"
    fi
fi

# ==================== Done ====================
echo ""
echo -e "${GREEN}============================================"
echo "  NexusRoute Uninstall Complete!"
echo -e "============================================${NC}"
echo ""
echo "  System restored to pre-installation state."
echo "  Run 'netplan apply' or reboot to reset LAN interface."
echo ""
