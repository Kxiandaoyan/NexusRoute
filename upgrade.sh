#!/bin/bash
#
# NexusRoute - Upgrade Script
# Downloads latest code from GitHub and upgrades in-place.
#
# What is PRESERVED (never touched):
#   - db.sqlite           (users, nodes, routes)
#   - config.json         (WAN/LAN interface names set at install time)
#   - .jwt_secret         (JWT signing key)
#   - /etc/dnsmasq.d/     (per-device DHCP static bindings)
#   - /etc/netplan/       (network interface config)
#   - xray-user*.service  (per-user Xray systemd units)
#   - config-user*.json   (per-user Xray proxy configs, regenerated on demand)
#
# What is UPDATED:
#   - server.js, package.json
#   - public/index.html, public/admin.html
#   - iptables_rules.sh, uninstall.sh, upgrade.sh (self)
#   - npm dependencies (if package.json changed)
#   - iptables rules (cleared + rebuilt from DB to apply any rule changes)
#   - dnsmasq DNS server setting (migrates old 127.0.0.1#5353 -> 8.8.8.8)
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${BLUE}==== $1 ====${NC}\n"; }

# ==================== Pre-flight checks ====================

if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root: sudo ./upgrade.sh"
    exit 1
fi

INSTALL_DIR="/opt/nexusroute"
GITHUB_URL="https://github.com/Kxiandaoyan/NexusRoute/archive/refs/heads/main.tar.gz"
TMP_DIR=$(mktemp -d)
BACKUP_DIR="/opt/nexusroute_upgrade_backup_$(date +%Y%m%d_%H%M%S)"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  NexusRoute Upgrade${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

if [ ! -d "$INSTALL_DIR" ]; then
    log_error "$INSTALL_DIR not found. Run install.sh first."
    exit 1
fi

if [ ! -f "$INSTALL_DIR/db.sqlite" ]; then
    log_error "Database not found at $INSTALL_DIR/db.sqlite. Run install.sh first."
    exit 1
fi

# ==================== Step 1: Backup ====================
log_step "Step 1/6: Backup current installation"

mkdir -p "$BACKUP_DIR/public"
for f in server.js package.json iptables_rules.sh uninstall.sh; do
    [ -f "$INSTALL_DIR/$f" ] && cp "$INSTALL_DIR/$f" "$BACKUP_DIR/"
done
[ -d "$INSTALL_DIR/public" ] && cp -r "$INSTALL_DIR/public/"* "$BACKUP_DIR/public/" 2>/dev/null || true
# Always backup the DB even though we never touch it
cp "$INSTALL_DIR/db.sqlite" "$BACKUP_DIR/db.sqlite"

log_info "Backup saved to $BACKUP_DIR"
log_info "Database record count: $(sqlite3 "$INSTALL_DIR/db.sqlite" 'SELECT COUNT(*) FROM users;' 2>/dev/null || echo '?') users"

# ==================== Step 2: Download ====================
log_step "Step 2/6: Download latest code from GitHub"

log_info "Fetching $GITHUB_URL ..."
if command -v wget &>/dev/null; then
    wget -q --show-progress -O "$TMP_DIR/repo.tar.gz" "$GITHUB_URL"
elif command -v curl &>/dev/null; then
    curl -L --progress-bar -o "$TMP_DIR/repo.tar.gz" "$GITHUB_URL"
else
    log_error "Neither wget nor curl found. Install one and retry."
    exit 1
fi

tar -xzf "$TMP_DIR/repo.tar.gz" -C "$TMP_DIR"
SRC=$(find "$TMP_DIR" -maxdepth 1 -type d -name "NexusRoute-*" | head -1)

if [ -z "$SRC" ]; then
    log_error "Failed to extract archive. Check network and try again."
    exit 1
fi

log_info "Downloaded: $(ls "$SRC")"

# ==================== Step 3: Update application files ====================
log_step "Step 3/6: Update application files"

copy_if_exists() {
    local src="$1" dst="$2"
    if [ -e "$src" ]; then
        cp -r "$src" "$dst"
        log_info "Updated: $(basename "$dst")"
    else
        log_warn "Not found in download, skipping: $(basename "$src")"
    fi
}

copy_if_exists "$SRC/server.js"          "$INSTALL_DIR/server.js"
copy_if_exists "$SRC/iptables_rules.sh"  "$INSTALL_DIR/iptables_rules.sh"
copy_if_exists "$SRC/uninstall.sh"       "$INSTALL_DIR/uninstall.sh"
copy_if_exists "$SRC/upgrade.sh"         "$INSTALL_DIR/upgrade.sh"

# Frontend
if [ -d "$SRC/public" ]; then
    cp -r "$SRC/public/"* "$INSTALL_DIR/public/"
    log_info "Updated: public/ (index.html, admin.html)"
fi

# package.json - update but flag if deps changed
OLD_JSON=$(cat "$INSTALL_DIR/package.json" 2>/dev/null || echo "")
copy_if_exists "$SRC/package.json" "$INSTALL_DIR/package.json"
NEW_JSON=$(cat "$INSTALL_DIR/package.json" 2>/dev/null || echo "")

chmod +x "$INSTALL_DIR/iptables_rules.sh" "$INSTALL_DIR/uninstall.sh" "$INSTALL_DIR/upgrade.sh" 2>/dev/null || true

# ==================== Step 4: npm dependencies ====================
log_step "Step 4/6: Update npm dependencies"

cd "$INSTALL_DIR"
if [ "$OLD_JSON" != "$NEW_JSON" ]; then
    log_info "package.json changed - running npm install..."
    npm install --production 2>&1 | tail -5
    log_info "Dependencies updated"
else
    log_info "package.json unchanged - skipping npm install"
fi
cd - > /dev/null

# ==================== Step 5: Migrate dnsmasq DNS setting ====================
log_step "Step 5/6: Migrate dnsmasq configuration (if needed)"

DNSMASQ_CONF="/etc/dnsmasq.conf"
if [ -f "$DNSMASQ_CONF" ] && grep -q "server=127.0.0.1#5353" "$DNSMASQ_CONF"; then
    log_info "Old DNS setting found (127.0.0.1#5353) - migrating to 8.8.8.8/1.1.1.1..."
    cp "$DNSMASQ_CONF" "${DNSMASQ_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    sed -i 's|^# DNS via Xray|# System DNS for gateway itself (client DNS is intercepted by iptables per-user)|' "$DNSMASQ_CONF"
    sed -i 's|^server=127.0.0.1#5353|server=8.8.8.8\nserver=1.1.1.1|' "$DNSMASQ_CONF"
    systemctl reload dnsmasq 2>/dev/null || systemctl restart dnsmasq 2>/dev/null || true
    log_info "dnsmasq DNS setting migrated and reloaded"
else
    log_info "dnsmasq config already up-to-date, no changes needed"
fi

# ==================== Step 6: Reload iptables + restart services ====================
log_step "Step 6/6: Reload iptables rules and restart services"

log_info "Rebuilding iptables rules from database..."
"$INSTALL_DIR/iptables_rules.sh" setup
log_info "iptables rules rebuilt"

log_info "Restarting NexusRoute service..."
systemctl restart nexusroute
sleep 2

if ! systemctl is-active --quiet nexusroute; then
    log_error "NexusRoute failed to start after upgrade! Rolling back server.js..."
    cp "$BACKUP_DIR/server.js" "$INSTALL_DIR/server.js"
    [ -f "$BACKUP_DIR/package.json" ] && cp "$BACKUP_DIR/package.json" "$INSTALL_DIR/package.json"
    systemctl restart nexusroute
    log_warn "Rolled back. Check logs: journalctl -u nexusroute -n 50"
    exit 1
fi

log_info "NexusRoute service running"

# Restart active Xray user services so they pick up any config changes
RESTARTED=0
for svc in $(systemctl list-units --type=service --state=active 2>/dev/null | grep -oP 'xray-user\d+' || true); do
    if systemctl restart "$svc" 2>/dev/null; then
        RESTARTED=$((RESTARTED + 1))
    fi
done

if [ "$RESTARTED" -gt 0 ]; then
    log_info "Restarted $RESTARTED user Xray service(s)"
else
    log_info "No active Xray user services (normal if no devices are connected)"
fi

# ==================== Done ====================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  NexusRoute Upgrade Complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  Backup location : $BACKUP_DIR"
echo "  Database        : preserved ($INSTALL_DIR/db.sqlite)"
echo "  Config          : preserved ($INSTALL_DIR/config.json)"
echo ""
echo "  User Panel  : http://$(grep -o '"lan_ip":"[^"]*"' "$INSTALL_DIR/config.json" 2>/dev/null | cut -d'"' -f4 || echo '192.168.100.1')/"
echo "  Admin Panel : http://$(grep -o '"lan_ip":"[^"]*"' "$INSTALL_DIR/config.json" 2>/dev/null | cut -d'"' -f4 || echo '192.168.100.1')/admin"
echo ""
echo "  Logs: journalctl -u nexusroute -f"
echo ""
