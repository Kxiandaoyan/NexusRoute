#!/bin/bash

# NexusRoute - 修复待审批设备功能
# 用于修复从旧版本升级后缺失 pending_devices 表的问题

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    log_error "请使用 root 权限运行此脚本 (sudo)"
    exit 1
fi

DB_PATH="/opt/nexusroute/db.sqlite"

echo "========================================"
echo "  修复待审批设备功能"
echo "========================================"
echo ""

# 检查数据库文件
if [ ! -f "$DB_PATH" ]; then
    log_error "数据库文件不存在: $DB_PATH"
    exit 1
fi

log_info "检查 pending_devices 表..."

# 检查表是否存在
TABLE_EXISTS=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='pending_devices';" | wc -l)

if [ "$TABLE_EXISTS" -eq 0 ]; then
    log_info "pending_devices 表不存在，正在创建..."

    sqlite3 "$DB_PATH" <<EOF
CREATE TABLE IF NOT EXISTS pending_devices (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  mac_address TEXT UNIQUE NOT NULL,
  first_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
  last_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
  hostname TEXT,
  status TEXT DEFAULT 'pending'
);

CREATE INDEX IF NOT EXISTS idx_pending_devices_status ON pending_devices(status);
CREATE INDEX IF NOT EXISTS idx_pending_devices_mac ON pending_devices(mac_address);
EOF

    log_success "pending_devices 表创建成功"
else
    log_info "pending_devices 表已存在"
fi

# 重启服务
log_info "重启 NexusRoute 服务..."
systemctl restart nexusroute

sleep 2

# 检查服务状态
if systemctl is-active --quiet nexusroute; then
    log_success "NexusRoute 服务运行正常"
else
    log_error "NexusRoute 服务启动失败"
    log_error "查看日志: journalctl -u nexusroute -n 50"
    exit 1
fi

echo ""
echo "========================================"
log_success "修复完成！"
echo "========================================"
echo ""
log_info "现在可以访问管理后台查看待审批设备"
log_info "管理后台: http://192.168.100.1/admin"
echo ""
log_info "如果仍然看不到待审批设备，请运行诊断工具："
log_info "node /opt/nexusroute/check-pending-devices.js"
echo ""
