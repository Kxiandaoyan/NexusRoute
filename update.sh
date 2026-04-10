#!/bin/bash

# NexusRoute Update Script
# This script downloads and updates the NexusRoute installation from GitHub

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
GITHUB_REPO="https://github.com/YOUR_USERNAME/NexusRoute"
GITHUB_BRANCH="main"
INSTALL_DIR="/opt/nexusroute"
DB_PATH="$INSTALL_DIR/db.sqlite"
BACKUP_DIR="$INSTALL_DIR/backup_$(date +%Y%m%d_%H%M%S)"
TEMP_DIR="/tmp/nexusroute_update_$$"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Cleanup function
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root (use sudo)"
    exit 1
fi

# Check if NexusRoute is installed
if [ ! -d "$INSTALL_DIR" ]; then
    log_error "NexusRoute is not installed at $INSTALL_DIR"
    exit 1
fi

echo "========================================"
echo "  NexusRoute Update Script"
echo "========================================"
echo ""

# Step 1: Check dependencies
log_info "Checking dependencies..."
if ! command -v git &> /dev/null; then
    log_error "git is not installed. Installing..."
    apt-get update -qq
    apt-get install -y git
fi

if ! command -v curl &> /dev/null; then
    log_error "curl is not installed. Installing..."
    apt-get update -qq
    apt-get install -y curl
fi

# Step 2: Download latest version
log_info "Downloading latest version from GitHub..."
mkdir -p "$TEMP_DIR"

if git clone --depth 1 --branch "$GITHUB_BRANCH" "$GITHUB_REPO" "$TEMP_DIR" 2>/dev/null; then
    log_success "Downloaded from GitHub"
else
    log_warn "Git clone failed, trying direct download..."
    # Fallback to direct download
    curl -L "${GITHUB_REPO}/archive/refs/heads/${GITHUB_BRANCH}.zip" -o "$TEMP_DIR/repo.zip"
    unzip -q "$TEMP_DIR/repo.zip" -d "$TEMP_DIR"
    mv "$TEMP_DIR/NexusRoute-${GITHUB_BRANCH}"/* "$TEMP_DIR/"
    log_success "Downloaded from GitHub (direct)"
fi

# Verify downloaded files
if [ ! -f "$TEMP_DIR/server.js" ]; then
    log_error "Downloaded files are incomplete (server.js not found)"
    exit 1
fi

# Step 3: Create backup
log_info "Creating backup..."
mkdir -p "$BACKUP_DIR"
cp -r "$INSTALL_DIR"/*.js "$BACKUP_DIR/" 2>/dev/null || true
cp -r "$INSTALL_DIR"/public "$BACKUP_DIR/" 2>/dev/null || true
cp "$DB_PATH" "$BACKUP_DIR/db.sqlite" 2>/dev/null || true
log_success "Backup created at $BACKUP_DIR"

# Step 4: Stop service
log_info "Stopping NexusRoute service..."
systemctl stop nexusroute
log_success "Service stopped"

# Step 5: Update files
log_info "Updating files..."

# Copy server.js
cp "$TEMP_DIR/server.js" "$INSTALL_DIR/server.js"
log_success "Updated server.js"

# Copy public directory
if [ -d "$TEMP_DIR/public" ]; then
    cp -r "$TEMP_DIR/public"/* "$INSTALL_DIR/public/"
    log_success "Updated public files"
fi

# Copy other files if they exist
if [ -f "$TEMP_DIR/package.json" ]; then
    cp "$TEMP_DIR/package.json" "$INSTALL_DIR/package.json"
    log_success "Updated package.json"
fi

# Step 6: Database migration
log_info "Checking database schema..."

# Check if hop_level column exists
HOP_LEVEL_EXISTS=$(sqlite3 "$DB_PATH" "PRAGMA table_info(nodes);" | grep -c "hop_level" || true)

if [ "$HOP_LEVEL_EXISTS" -eq 0 ]; then
    log_info "Applying database migration: adding hop_level column..."

    if [ -f "$TEMP_DIR/migrate_add_hop_level.sql" ]; then
        sqlite3 "$DB_PATH" < "$TEMP_DIR/migrate_add_hop_level.sql"
        log_success "Database migration completed"
    else
        log_warn "Migration file not found, applying inline migration..."
        sqlite3 "$DB_PATH" <<EOF
ALTER TABLE nodes ADD COLUMN hop_level INTEGER DEFAULT 1;
CREATE INDEX IF NOT EXISTS idx_nodes_hop_level ON nodes(hop_level, enabled);
UPDATE nodes SET hop_level = 1 WHERE hop_level IS NULL;
EOF
        log_success "Database migration completed"
    fi
else
    log_info "Database schema is up to date"
fi

# Step 7: Install/update dependencies
log_info "Checking dependencies..."
cd "$INSTALL_DIR"

if [ -f "package.json" ]; then
    if command -v npm &> /dev/null; then
        npm install --production --silent
        log_success "Dependencies updated"
    else
        log_warn "npm not found, skipping dependency update"
    fi
fi

# Step 8: Start service
log_info "Starting NexusRoute service..."
systemctl start nexusroute
sleep 2

# Step 9: Check service status
if systemctl is-active --quiet nexusroute; then
    log_success "NexusRoute service is running"
else
    log_error "Failed to start NexusRoute service"
    log_error "Check logs with: journalctl -u nexusroute -n 50"
    log_info "Restoring from backup..."

    systemctl stop nexusroute
    cp "$BACKUP_DIR"/*.js "$INSTALL_DIR/" 2>/dev/null || true
    cp -r "$BACKUP_DIR"/public/* "$INSTALL_DIR/public/" 2>/dev/null || true
    cp "$BACKUP_DIR/db.sqlite" "$DB_PATH" 2>/dev/null || true
    systemctl start nexusroute

    log_warn "Restored from backup"
    exit 1
fi

# Step 10: Display status
echo ""
echo "========================================"
log_success "Update completed successfully!"
echo "========================================"
echo ""
log_info "Service status:"
systemctl status nexusroute --no-pager -l | head -n 10
echo ""
log_info "Backup location: $BACKUP_DIR"
log_info "Access admin panel: http://192.168.100.1/admin"
log_info "Access user panel: http://192.168.100.1/"
echo ""
log_info "To view logs: journalctl -u nexusroute -f"
log_info "To remove backup: rm -rf $BACKUP_DIR"
echo ""
