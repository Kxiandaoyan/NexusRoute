#!/bin/bash
#
# NexusRoute - One-Click Installation Script
# Supports: Ubuntu/Debian Server
# Can be run repeatedly - will remove old installation and reinstall
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
log_step()  { echo -e "\n${BLUE}==== Step $1/$2: $3 ====${NC}\n"; }

if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root (sudo ./install.sh)"
    exit 1
fi

TOTAL_STEPS=9
STEP=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/nexusroute"

# ===================== Step 1: Interface Selection =====================
STEP=$((STEP + 1))
log_step $STEP $TOTAL_STEPS "Select Network Interfaces"

echo "Available network interfaces:"
echo ""
mapfile -t IFACES < <(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$')
i=1
for iface in "${IFACES[@]}"; do
    ip_addr=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
    status=$(ip link show "$iface" | grep -oP 'state \K\w+')
    printf "  [%d] %-12s  %-15s  (%s)\n" "$i" "$iface" "${ip_addr:---}" "$status"
    i=$((i + 1))
done
echo ""

# Select WAN interface
while true; do
    read -p "Select WAN interface (internet): " wan_num
    WAN_IF="${IFACES[$((wan_num - 1))]}"
    [ -n "$WAN_IF" ] && break
    log_error "Invalid selection"
done

# Select LAN interface
while true; do
    read -p "Select LAN interface (devices): " lan_num
    LAN_IF="${IFACES[$((lan_num - 1))]}"
    [ -n "$LAN_IF" ] && [ "$LAN_IF" != "$WAN_IF" ] && break
    [ "$LAN_IF" = "$WAN_IF" ] ] && log_error "LAN must be different from WAN"
    log_error "Invalid selection"
done

log_info "WAN=$WAN_IF  LAN=$LAN_IF"

# Verify WAN has internet
log_info "Checking internet on $WAN_IF..."
if ! ping -c 2 -W 5 -I "$WAN_IF" 8.8.8.8 &>/dev/null; then
    log_warn "$WAN_IF cannot reach 8.8.8.8 - continue anyway? (y/N)"
    read -r ans
    [ "$ans" != "y" ] && [ "$ans" != "Y" ] && exit 1
fi

# ===================== Step 2: Admin Password =====================
STEP=$((STEP + 1))
log_step $STEP $TOTAL_STEPS "Set Admin Password"

while true; do
    read -sp "Admin password (min 8 chars): " password1; echo
    [ ${#password1} -lt 8 ] && log_error "Too short" && continue
    read -sp "Confirm password: " password2; echo
    [ "$password1" = "$password2" ] && ADMIN_PASSWORD="$password1" && break
    log_error "Passwords do not match"
done
log_info "Password set"

# ===================== Step 3: Clean Old Installation =====================
STEP=$((STEP + 1))
log_step $STEP $TOTAL_STEPS "Prepare Installation"

# Stop old services
log_info "Stopping old services..."
systemctl stop nexusroute 2>/dev/null || true
for svc in $(systemctl list-units --type=service --all 2>/dev/null | grep -oP 'xray-user\d+'); do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service"
done
systemctl daemon-reload 2>/dev/null || true

# Backup database if exists
if [ -f "$INSTALL_DIR/db.sqlite" ]; then
    BACKUP="/opt/nexusroute_db_backup_$(date +%Y%m%d_%H%M%S).sqlite"
    cp "$INSTALL_DIR/db.sqlite" "$BACKUP"
    log_info "Database backed up to $BACKUP"
fi

# Remove old installation
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/public"
log_info "Clean installation directory ready"

# ===================== Step 4: Install Dependencies =====================
STEP=$((STEP + 1))
log_step $STEP $TOTAL_STEPS "Install Dependencies"

log_info "Updating package list..."
apt-get update -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 || {
    log_warn "apt update failed, retrying..."
    sleep 5
    apt-get update -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 || true
}

log_info "Installing tools..."
apt-get install -y curl wget unzip sqlite3 jq iptables-persistent

# Node.js 18
if command -v node &>/dev/null && [[ "$(node -v)" =~ ^v1[89]\. ]]; then
    log_info "Node.js $(node -v) already installed"
else
    log_info "Installing Node.js 18..."
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
    apt-get install -y nodejs
fi
log_info "Node.js $(node -v) / npm $(npm -v)"

# Xray
if [ -f "/usr/local/bin/xray" ]; then
    log_info "Xray already installed ($(/usr/local/bin/xray version | head -1))"
else
    log_info "Installing Xray-core..."
    wget -q --show-progress -O /tmp/xray.zip \
        https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
    unzip -q -o /tmp/xray.zip -d /tmp/xray
    mv /tmp/xray/xray /usr/local/bin/xray
    chmod +x /usr/local/bin/xray
    setcap cap_net_admin,cap_net_bind_service=ep /usr/local/bin/xray
    mkdir -p /usr/local/etc/xray
    rm -rf /tmp/xray /tmp/xray.zip
    log_info "Xray installed: $(/usr/local/bin/xray version | head -1)"
fi

# dnsmasq
apt-get install -y dnsmasq
systemctl stop dnsmasq 2>/dev/null || true

# ===================== Step 5: Configure LAN Interface =====================
STEP=$((STEP + 1))
log_step $STEP $TOTAL_STEPS "Configure LAN Interface ($LAN_IF)"

LAN_IP="192.168.100.1"
LAN_SUBNET="192.168.100"
DHCP_START="192.168.100.10"
DHCP_END="192.168.100.209"

if ip addr show "$LAN_IF" | grep -q "$LAN_IP/24"; then
    log_info "$LAN_IF already has $LAN_IP/24"
else
    NETPLAN_FILE="/etc/netplan/99-nexusroute.yaml"
    cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $LAN_IF:
      dhcp4: false
      addresses:
        - $LAN_IP/24
EOF
    netplan apply
    sleep 2
    if ip addr show "$LAN_IF" | grep -q "$LAN_IP/24"; then
        log_info "$LAN_IF configured: $LAN_IP/24"
    else
        log_error "Failed to configure $LAN_IF"
        exit 1
    fi
fi

# Write config.json for server.js and iptables_rules.sh
cat > "$INSTALL_DIR/config.json" <<EOF
{
  "wan_if": "$WAN_IF",
  "lan_if": "$LAN_IF",
  "lan_ip": "$LAN_IP",
  "lan_subnet": "$LAN_SUBNET"
}
EOF
log_info "config.json written"

# ===================== Step 6: Configure dnsmasq =====================
STEP=$((STEP + 1))
log_step $STEP $TOTAL_STEPS "Configure dnsmasq (DHCP + DNS)"

cat > /etc/dnsmasq.conf <<EOF
# NexusRoute dnsmasq

port=53
interface=$LAN_IF
listen-address=$LAN_IP
bind-interfaces

no-resolv
no-hosts

# DNS via Xray
server=127.0.0.1#5353

# DHCP - permanent lease, all devices get fixed IPs
dhcp-range=$DHCP_START,$DHCP_END,infinite
dhcp-option=3,$LAN_IP
dhcp-option=6,$LAN_IP
log-dhcp

conf-dir=/etc/dnsmasq.d
EOF

# Clear any leftover dnsmasq config snippets that might add listen-address
mkdir -p /etc/dnsmasq.d
rm -f /etc/dnsmasq.d/*.conf /etc/dnsmasq.d/*.dpkg-* 2>/dev/null || true
log_info "dnsmasq configured (DHCP range $DHCP_START-$DHCP_END, permanent lease)"

# System DNS - dnsmasq handles LAN devices only, Ubuntu uses public DNS directly
# Must fully kill systemd-resolved so it can't reclaim port 53
systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true
systemctl mask systemd-resolved 2>/dev/null || true
# Kill anything still on port 53
fuser -k 53/tcp 53/udp 2>/dev/null || true
sleep 1
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<DNS
nameserver 8.8.8.8
nameserver 1.1.1.1
DNS
log_info "System DNS configured (8.8.8.8, 1.1.1.1)"

# ===================== Step 7: Deploy Application =====================
STEP=$((STEP + 1))
log_step $STEP $TOTAL_STEPS "Deploy Application"

cp "$SCRIPT_DIR/server.js"       "$INSTALL_DIR/" 2>/dev/null && log_info "server.js"       || log_warn "server.js not found"
cp "$SCRIPT_DIR/package.json"    "$INSTALL_DIR/" 2>/dev/null && log_info "package.json"    || log_warn "package.json not found"
cp "$SCRIPT_DIR/iptables_rules.sh" "$INSTALL_DIR/" 2>/dev/null && log_info "iptables_rules.sh" || log_warn "iptables_rules.sh not found"
chmod +x "$INSTALL_DIR/iptables_rules.sh" 2>/dev/null || true

if [ -d "$SCRIPT_DIR/public" ]; then
    cp -r "$SCRIPT_DIR/public/"* "$INSTALL_DIR/public/"
    log_info "Frontend files"
fi

cd "$INSTALL_DIR"
npm install --production 2>/dev/null || npm install
cd -
log_info "Dependencies installed"

# ===================== Step 8: Initialize Database =====================
STEP=$((STEP + 1))
log_step $STEP $TOTAL_STEPS "Initialize Database"

ADMIN_PASSWORD_HASH=$(cd "$INSTALL_DIR" && node -e "
const bcrypt = require('bcryptjs');
console.log(bcrypt.hashSync('$ADMIN_PASSWORD', 10));
" 2>/dev/null)

if [ -z "$ADMIN_PASSWORD_HASH" ]; then
    ADMIN_PASSWORD_HASH=$(echo -n "$ADMIN_PASSWORD" | sha256sum | cut -d' ' -f1)
    log_warn "Using SHA256 hash (install bcryptjs for better security)"
fi

sqlite3 "$INSTALL_DIR/db.sqlite" <<EOF
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT UNIQUE NOT NULL,
  mac_address TEXT UNIQUE NOT NULL,
  ip_address TEXT UNIQUE NOT NULL,
  xray_port INTEGER UNIQUE NOT NULL,
  iptables_mark INTEGER UNIQUE NOT NULL,
  enabled BOOLEAN DEFAULT 1,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS nodes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  protocol TEXT NOT NULL,
  address TEXT NOT NULL,
  port INTEGER NOT NULL,
  uuid TEXT,
  alter_id INTEGER DEFAULT 0,
  password TEXT,
  encryption TEXT DEFAULT 'auto',
  network TEXT DEFAULT 'tcp',
  tls TEXT DEFAULT 'none',
  sni TEXT,
  alpn TEXT,
  fingerprint TEXT,
  ws_path TEXT,
  ws_host TEXT,
  grpc_service_name TEXT,
  grpc_mode TEXT DEFAULT 'gun',
  flow TEXT,
  remarks TEXT,
  hop_level INTEGER DEFAULT 1,
  enabled BOOLEAN DEFAULT 1,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS user_routes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  node1_id INTEGER NOT NULL,
  node2_id INTEGER,
  node3_id INTEGER,
  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  FOREIGN KEY (node1_id) REFERENCES nodes(id),
  FOREIGN KEY (node2_id) REFERENCES nodes(id),
  FOREIGN KEY (node3_id) REFERENCES nodes(id)
);

CREATE TABLE IF NOT EXISTS admins (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

INSERT OR REPLACE INTO admins (id, username, password_hash)
VALUES (1, 'admin', '$ADMIN_PASSWORD_HASH');
EOF

log_info "Database initialized"

# ===================== Step 9: Start Services =====================
STEP=$((STEP + 1))
log_step $STEP $TOTAL_STEPS "Start Services"

# systemd service for NexusRoute
cat > /etc/systemd/system/nexusroute.service <<EOF
[Unit]
Description=NexusRoute Multi-User Proxy Gateway
After=network.target dnsmasq.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/node $INSTALL_DIR/server.js
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dnsmasq nexusroute

# Ensure port 53 is free before starting dnsmasq
fuser -k 53/tcp 53/udp 2>/dev/null || true
sleep 1

log_info "Starting dnsmasq..."
if ! systemctl start dnsmasq; then
    log_error "dnsmasq failed to start, checking port 53..."
    ss -tlnp | grep ':53 ' || true
    log_error "Check: journalctl -u dnsmasq -n 20"
    exit 1
fi
sleep 1

log_info "Starting NexusRoute..."
systemctl start nexusroute
sleep 2

# Verify
if systemctl is-active --quiet nexusroute && systemctl is-active --quiet dnsmasq; then
    log_info "All services running"
else
    log_error "Service failed - check: journalctl -u nexusroute -n 50"
    exit 1
fi

# Configure iptables
log_info "Setting up iptables rules..."
"$INSTALL_DIR/iptables_rules.sh" setup

# ===================== Done =====================
echo ""
echo -e "${GREEN}============================================"
echo "  NexusRoute Installation Complete!"
echo -e "============================================${NC}"
echo ""
echo "  Interfaces:  WAN=$WAN_IF  LAN=$LAN_IF"
echo "  User Panel:  http://$LAN_IP/"
echo "  Admin Panel: http://$LAN_IP/admin"
echo "  Admin Login: admin / (your password)"
echo ""
echo "  Devices connecting to LAN will be"
echo "  automatically configured with proxy."
echo ""
echo "  Logs: journalctl -u nexusroute -f"
echo ""
