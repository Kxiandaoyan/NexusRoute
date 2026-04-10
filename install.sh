#!/bin/bash
#
# NexusRoute One-Click Installation Script
# For Ubuntu Server 22.04 LTS
#

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

log_step() {
    echo -e "${BLUE}[STEP $1/$2]${NC} $3"
}

# Check root privileges
if [ "$EUID" -ne 0 ]; then
    log_error "Please run this script with root privileges"
    exit 1
fi

TOTAL_STEPS=10
CURRENT_STEP=0

# Step 1: Check system environment
next_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    log_step $CURRENT_STEP $TOTAL_STEPS "$1"
}

next_step "Checking system environment"

# Check OS version
if [ ! -f /etc/os-release ]; then
    log_error "Cannot detect OS version"
    exit 1
fi

source /etc/os-release
if [ "$VERSION_CODENAME" != "jammy" ]; then
    log_error "This script only supports Ubuntu 22.04 LTS (jammy)"
    log_error "Current system: $PRETTY_NAME"
    exit 1
fi

log_info "OS check passed: $PRETTY_NAME"

# Check network interfaces
if ! ip link show eth0 &>/dev/null; then
    log_error "eth0 interface not detected"
    log_error "Please ensure VM is connected to Nexus_WAN switch"
    exit 1
fi

if ! ip link show eth1 &>/dev/null; then
    log_error "eth1 interface not detected"
    log_error "Please ensure VM is connected to Nexus_LAN_Isolated switch"
    exit 1
fi

log_info "Network interface check passed: eth0, eth1"

# Check eth0 internet connectivity
log_info "Checking eth0 internet connectivity..."
if ! ping -c 2 -W 5 8.8.8.8 &>/dev/null; then
    log_error "eth0 cannot access the internet"
    log_error "Please check Nexus_WAN switch configuration"
    exit 1
fi

log_info "Internet connectivity check passed"

# Check if already installed
if [ -d "/opt/nexusroute" ]; then
    log_warn "Existing NexusRoute installation detected"
    read -p "Overwrite installation? This will delete all existing data (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log_info "Installation cancelled"
        exit 0
    fi

    log_warn "Stopping existing services..."
    systemctl stop nexusroute 2>/dev/null || true
    systemctl stop xray-user* 2>/dev/null || true

    log_warn "Backing up existing database..."
    if [ -f "/opt/nexusroute/db.sqlite" ]; then
        cp /opt/nexusroute/db.sqlite /opt/nexusroute/db.sqlite.backup.$(date +%Y%m%d_%H%M%S)
        log_info "Database backed up"
    fi
fi

# Step 2: Set admin password
next_step "Setting admin password"

while true; do
    read -sp "Enter admin password (at least 8 characters): " password1
    echo

    if [ ${#password1} -lt 8 ]; then
        log_error "Password must be at least 8 characters, please try again"
        continue
    fi

    read -sp "Confirm admin password: " password2
    echo

    if [ "$password1" = "$password2" ]; then
        ADMIN_PASSWORD="$password1"
        log_info "Admin password set successfully"
        break
    else
        log_error "Passwords do not match, please try again"
    fi
done

# Step 3: Configure network interfaces
next_step "Configuring eth1 network interface"

log_info "Configuring eth1 static IP: 192.168.100.1/24"

# Check if eth1 already has the correct IP
if ip addr show eth1 | grep -q "192.168.100.1/24"; then
    log_info "eth1 already configured with 192.168.100.1/24, skipping"
else
    # Create a separate netplan configuration file for eth1 only
    # This will not affect eth0's existing configuration
    NETPLAN_ETH1_FILE="/etc/netplan/99-nexusroute-eth1.yaml"

    log_info "Creating netplan configuration for eth1: $NETPLAN_ETH1_FILE"

    cat > "$NETPLAN_ETH1_FILE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    eth1:
      dhcp4: false
      addresses:
        - 192.168.100.1/24
EOF

    log_info "Applying netplan configuration..."
    netplan apply

    # Wait for network configuration to take effect
    sleep 2

    # Verify configuration
    if ip addr show eth1 | grep -q "192.168.100.1/24"; then
        log_info "eth1 configured successfully"
    else
        log_error "eth1 configuration failed"
        exit 1
    fi
fi

# Step 4: Update system and install basic dependencies
next_step "Updating system and installing basic dependencies"

log_info "Updating package list (this may take a few minutes)..."
# Remove -qq to show progress, add timeout
apt-get update -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 || {
    log_warn "apt-get update failed, retrying..."
    sleep 5
    apt-get update -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30
}

log_info "Installing basic tools..."
apt-get install -y curl wget unzip sqlite3 jq iptables-persistent

# Step 5: Install Node.js 18.x
next_step "Installing Node.js 18.x"

if command -v node &> /dev/null; then
    NODE_VERSION=$(node -v)
    log_info "Detected existing Node.js: $NODE_VERSION"

    if [[ "$NODE_VERSION" =~ ^v18\. ]]; then
        log_info "Node.js version meets requirements, skipping installation"
    else
        log_warn "Node.js version does not meet requirements, reinstalling"
        apt-get remove -y nodejs 2>/dev/null || true
    fi
fi

if ! command -v node &> /dev/null || ! [[ "$(node -v)" =~ ^v18\. ]]; then
    log_info "Downloading NodeSource installation script..."
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash -

    log_info "Installing Node.js..."
    apt-get install -y nodejs
fi

NODE_VERSION=$(node -v)
NPM_VERSION=$(npm -v)
log_info "Node.js installed successfully: $NODE_VERSION"
log_info "npm version: $NPM_VERSION"

# Step 6: Install Xray-core
next_step "Installing Xray-core"

if [ -f "/usr/local/bin/xray" ]; then
    XRAY_VERSION=$(/usr/local/bin/xray version | head -n 1)
    log_info "Detected existing Xray: $XRAY_VERSION"
    read -p "Reinstall Xray? (y/N): " reinstall_xray

    if [ "$reinstall_xray" != "y" ] && [ "$reinstall_xray" != "Y" ]; then
        log_info "Skipping Xray installation"
    else
        rm -f /usr/local/bin/xray
    fi
fi

if [ ! -f "/usr/local/bin/xray" ]; then
    log_info "Downloading latest Xray-core..."
    wget -q --show-progress -O /tmp/xray.zip \
        https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip

    log_info "Extracting Xray..."
    unzip -q -o /tmp/xray.zip -d /tmp/xray

    log_info "Installing Xray to /usr/local/bin..."
    mv /tmp/xray/xray /usr/local/bin/xray
    chmod +x /usr/local/bin/xray

    log_info "Setting network capabilities..."
    setcap cap_net_admin,cap_net_bind_service=ep /usr/local/bin/xray

    # Create configuration directory
    mkdir -p /usr/local/etc/xray

    # Clean up temporary files
    rm -rf /tmp/xray /tmp/xray.zip

    XRAY_VERSION=$(/usr/local/bin/xray version | head -n 1)
    log_info "Xray installed successfully: $XRAY_VERSION"
fi

# Step 7: Install and configure dnsmasq
next_step "Configuring dnsmasq"

log_info "Installing dnsmasq..."
apt-get install -y dnsmasq

log_info "Stopping dnsmasq service..."
systemctl stop dnsmasq

log_info "Configuring dnsmasq..."
cat > /etc/dnsmasq.conf <<EOF
# NexusRoute dnsmasq configuration

# Listen port and interface
port=53
interface=eth1
bind-interfaces

# Disable system hosts and resolv.conf
no-resolv
no-hosts

# DNS forwarding to Xray
server=127.0.0.1#5353

# DHCP configuration
dhcp-range=192.168.100.50,192.168.100.99,12h
dhcp-option=3,192.168.100.1
dhcp-option=6,192.168.100.1

# DHCP logging
log-dhcp

# Static binding configuration directory (dynamically generated by program)
conf-dir=/etc/dnsmasq.d
EOF

# Create static binding directory
mkdir -p /etc/dnsmasq.d

log_info "dnsmasq configuration completed"

# Step 8: Deploy NexusRoute application
next_step "Deploying NexusRoute application"

log_info "Creating application directory..."
mkdir -p /opt/nexusroute/public

log_info "Copying application files..."
# Note: Assumes script and application files are in the same directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/server.js" ]; then
    cp "$SCRIPT_DIR/server.js" /opt/nexusroute/
    log_info "server.js copied"
else
    log_warn "server.js not found, manual deployment required"
fi

if [ -f "$SCRIPT_DIR/package.json" ]; then
    cp "$SCRIPT_DIR/package.json" /opt/nexusroute/
    log_info "package.json copied"
fi

if [ -d "$SCRIPT_DIR/public" ]; then
    cp -r "$SCRIPT_DIR/public/"* /opt/nexusroute/public/
    log_info "Frontend files copied"
else
    log_warn "public directory not found, manual deployment required"
fi

# Install Node.js dependencies
if [ -f "/opt/nexusroute/package.json" ]; then
    log_info "Installing Node.js dependencies..."
    cd /opt/nexusroute
    npm install --production
    cd -
fi

# Step 9: Initialize database
next_step "Initializing database"

log_info "Creating database..."

# Generate password hash (using Node.js)
ADMIN_PASSWORD_HASH=$(node -e "
const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const hash = bcrypt.hashSync('$ADMIN_PASSWORD', 10);
console.log(hash);
" 2>/dev/null || echo "")

if [ -z "$ADMIN_PASSWORD_HASH" ]; then
    log_warn "bcryptjs not installed, using simple hash (not recommended for production)"
    ADMIN_PASSWORD_HASH=$(echo -n "$ADMIN_PASSWORD" | sha256sum | cut -d' ' -f1)
fi

# Create database tables
sqlite3 /opt/nexusroute/db.sqlite <<EOF
-- Users table
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

-- Nodes table
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

-- User routes table
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

-- Pending devices table
CREATE TABLE IF NOT EXISTS pending_devices (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  mac_address TEXT UNIQUE NOT NULL,
  first_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
  last_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
  hostname TEXT,
  status TEXT DEFAULT 'pending'
);

-- Admins table
CREATE TABLE IF NOT EXISTS admins (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Insert default admin account
INSERT OR REPLACE INTO admins (id, username, password_hash)
VALUES (1, 'admin', '$ADMIN_PASSWORD_HASH');
EOF

log_info "Database initialization completed"

# Step 10: Configure systemd services
next_step "Configuring systemd services"

log_info "Creating NexusRoute service..."
cat > /etc/systemd/system/nexusroute.service <<EOF
[Unit]
Description=NexusRoute Multi-User Proxy Gateway
After=network.target dnsmasq.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/nexusroute
ExecStart=/usr/bin/node /opt/nexusroute/server.js
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

log_info "Reloading systemd configuration..."
systemctl daemon-reload

log_info "Enabling services..."
systemctl enable nexusroute
systemctl enable dnsmasq

log_info "Starting services..."
systemctl start dnsmasq
systemctl start nexusroute

# Wait for services to start
sleep 3

# Check service status
if systemctl is-active --quiet nexusroute; then
    log_info "NexusRoute service started successfully"
else
    log_error "NexusRoute service failed to start"
    log_error "Check logs: journalctl -u nexusroute -n 50"
    exit 1
fi

if systemctl is-active --quiet dnsmasq; then
    log_info "dnsmasq service started successfully"
else
    log_error "dnsmasq service failed to start"
    log_error "Check logs: journalctl -u dnsmasq -n 50"
    exit 1
fi

# Configure iptables rules
log_info "Configuring iptables rules..."
if [ -f "$SCRIPT_DIR/iptables_rules.sh" ]; then
    cp "$SCRIPT_DIR/iptables_rules.sh" /opt/nexusroute/
    chmod +x /opt/nexusroute/iptables_rules.sh
    /opt/nexusroute/iptables_rules.sh setup
else
    log_warn "iptables_rules.sh not found, manual firewall configuration required"
fi

# Installation complete
echo ""
echo "=========================================="
echo -e "${GREEN}NexusRoute Installation Complete!${NC}"
echo "=========================================="
echo ""
echo "Access URLs:"
echo "  - User Frontend: http://192.168.100.1/"
echo "  - Admin Backend: http://192.168.100.1/admin"
echo ""
echo "Admin Account:"
echo "  - Username: admin"
echo "  - Password: (the password you just set)"
echo ""
echo "Next Steps:"
echo "  1. Access admin backend to add proxy nodes"
echo "  2. Connect Windows VM to Nexus_LAN_Isolated switch"
echo "  3. Windows VM will auto-acquire IP and appear in pending devices list"
echo "  4. Approve device in admin backend to start using"
echo ""
echo "Kill Switch Test:"
echo "  On Ubuntu: systemctl stop xray-user1"
echo "  On Windows VM: ping 8.8.8.8 (should timeout)"
echo ""
echo "Check Service Status:"
echo "  systemctl status nexusroute"
echo "  systemctl status dnsmasq"
echo ""
echo "View Logs:"
echo "  journalctl -u nexusroute -f"
echo "  journalctl -u dnsmasq -f"
echo ""
echo "=========================================="
