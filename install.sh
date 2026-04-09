#!/bin/bash
#
# NexusRoute 一键安装脚本
# 适用于 Ubuntu Server 22.04 LTS
#

set -e

# 颜色输出
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

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    log_error "请使用 root 权限运行此脚本"
    exit 1
fi

TOTAL_STEPS=10
CURRENT_STEP=0

# 步骤 1: 检查系统环境
next_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    log_step $CURRENT_STEP $TOTAL_STEPS "$1"
}

next_step "检查系统环境"

# 检查操作系统版本
if [ ! -f /etc/os-release ]; then
    log_error "无法检测操作系统版本"
    exit 1
fi

source /etc/os-release
if [ "$VERSION_CODENAME" != "jammy" ]; then
    log_error "此脚本仅支持 Ubuntu 22.04 LTS (jammy)"
    log_error "当前系统: $PRETTY_NAME"
    exit 1
fi

log_info "操作系统检查通过: $PRETTY_NAME"

# 检查网卡
if ! ip link show eth0 &>/dev/null; then
    log_error "未检测到 eth0 网卡"
    log_error "请确保虚拟机已连接到 Nexus_WAN 交换机"
    exit 1
fi

if ! ip link show eth1 &>/dev/null; then
    log_error "未检测到 eth1 网卡"
    log_error "请确保虚拟机已连接到 Nexus_LAN_Isolated 交换机"
    exit 1
fi

log_info "网卡检查通过: eth0, eth1"

# 检查 eth0 网络连接
log_info "检查 eth0 网络连接..."
if ! ping -c 2 -W 5 8.8.8.8 &>/dev/null; then
    log_error "eth0 无法访问互联网"
    log_error "请检查 Nexus_WAN 交换机配置"
    exit 1
fi

log_info "网络连接检查通过"

# 检查是否已安装
if [ -d "/opt/nexusroute" ]; then
    log_warn "检测到已安装的 NexusRoute"
    read -p "是否覆盖安装？这将删除所有现有数据 (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log_info "安装已取消"
        exit 0
    fi

    log_warn "停止现有服务..."
    systemctl stop nexusroute 2>/dev/null || true
    systemctl stop xray-user* 2>/dev/null || true

    log_warn "备份现有数据库..."
    if [ -f "/opt/nexusroute/db.sqlite" ]; then
        cp /opt/nexusroute/db.sqlite /opt/nexusroute/db.sqlite.backup.$(date +%Y%m%d_%H%M%S)
        log_info "数据库已备份"
    fi
fi

# 步骤 2: 输入管理员密码
next_step "设置管理员密码"

while true; do
    read -sp "请输入管理员密码（至少8位）: " password1
    echo

    if [ ${#password1} -lt 8 ]; then
        log_error "密码长度至少8位，请重新输入"
        continue
    fi

    read -sp "请确认管理员密码: " password2
    echo

    if [ "$password1" = "$password2" ]; then
        ADMIN_PASSWORD="$password1"
        log_info "管理员密码设置成功"
        break
    else
        log_error "两次密码不一致，请重新输入"
    fi
done

# 步骤 3: 配置网络接口
next_step "配置网络接口 eth1"

log_info "配置 eth1 静态 IP: 192.168.100.1/24"

# 查找 netplan 配置文件
NETPLAN_FILE=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n 1)

if [ -z "$NETPLAN_FILE" ]; then
    NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
fi

log_info "使用 netplan 配置文件: $NETPLAN_FILE"

# 备份原配置
if [ -f "$NETPLAN_FILE" ]; then
    cp "$NETPLAN_FILE" "${NETPLAN_FILE}.backup"
    log_info "原配置已备份到 ${NETPLAN_FILE}.backup"
fi

# 写入新配置
cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
    eth1:
      dhcp4: false
      addresses:
        - 192.168.100.1/24
EOF

log_info "应用 netplan 配置..."
netplan apply

# 等待网络配置生效
sleep 2

# 验证配置
if ip addr show eth1 | grep -q "192.168.100.1/24"; then
    log_info "eth1 配置成功"
else
    log_error "eth1 配置失败"
    exit 1
fi

# 步骤 4: 更新系统并安装基础依赖
next_step "更新系统并安装基础依赖"

log_info "更新软件包列表..."
apt-get update -qq

log_info "安装基础工具..."
apt-get install -y curl wget unzip sqlite3 jq iptables-persistent

# 步骤 5: 安装 Node.js 18.x
next_step "安装 Node.js 18.x"

if command -v node &> /dev/null; then
    NODE_VERSION=$(node -v)
    log_info "检测到已安装的 Node.js: $NODE_VERSION"

    if [[ "$NODE_VERSION" =~ ^v18\. ]]; then
        log_info "Node.js 版本符合要求，跳过安装"
    else
        log_warn "Node.js 版本不符合要求，将重新安装"
        apt-get remove -y nodejs 2>/dev/null || true
    fi
fi

if ! command -v node &> /dev/null || ! [[ "$(node -v)" =~ ^v18\. ]]; then
    log_info "下载 NodeSource 安装脚本..."
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash -

    log_info "安装 Node.js..."
    apt-get install -y nodejs
fi

NODE_VERSION=$(node -v)
NPM_VERSION=$(npm -v)
log_info "Node.js 安装成功: $NODE_VERSION"
log_info "npm 版本: $NPM_VERSION"

# 步骤 6: 安装 Xray-core
next_step "安装 Xray-core"

if [ -f "/usr/local/bin/xray" ]; then
    XRAY_VERSION=$(/usr/local/bin/xray version | head -n 1)
    log_info "检测到已安装的 Xray: $XRAY_VERSION"
    read -p "是否重新安装 Xray？(y/N): " reinstall_xray

    if [ "$reinstall_xray" != "y" ] && [ "$reinstall_xray" != "Y" ]; then
        log_info "跳过 Xray 安装"
    else
        rm -f /usr/local/bin/xray
    fi
fi

if [ ! -f "/usr/local/bin/xray" ]; then
    log_info "下载 Xray-core 最新版..."
    wget -q --show-progress -O /tmp/xray.zip \
        https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip

    log_info "解压 Xray..."
    unzip -q -o /tmp/xray.zip -d /tmp/xray

    log_info "安装 Xray 到 /usr/local/bin..."
    mv /tmp/xray/xray /usr/local/bin/xray
    chmod +x /usr/local/bin/xray

    log_info "设置网络权限..."
    setcap cap_net_admin,cap_net_bind_service=ep /usr/local/bin/xray

    # 创建配置目录
    mkdir -p /usr/local/etc/xray

    # 清理临时文件
    rm -rf /tmp/xray /tmp/xray.zip

    XRAY_VERSION=$(/usr/local/bin/xray version | head -n 1)
    log_info "Xray 安装成功: $XRAY_VERSION"
fi

# 步骤 7: 安装并配置 dnsmasq
next_step "配置 dnsmasq"

log_info "安装 dnsmasq..."
apt-get install -y dnsmasq

log_info "停止 dnsmasq 服务..."
systemctl stop dnsmasq

log_info "配置 dnsmasq..."
cat > /etc/dnsmasq.conf <<EOF
# NexusRoute dnsmasq 配置

# 监听端口和接口
port=53
interface=eth1
bind-interfaces

# 禁用系统 hosts 和 resolv.conf
no-resolv
no-hosts

# DNS 转发到 Xray
server=127.0.0.1#5353

# DHCP 配置
dhcp-range=192.168.100.50,192.168.100.99,12h
dhcp-option=3,192.168.100.1
dhcp-option=6,192.168.100.1

# DHCP 日志
log-dhcp

# 静态绑定配置文件（由程序动态生成）
conf-dir=/etc/dnsmasq.d
EOF

# 创建静态绑定目录
mkdir -p /etc/dnsmasq.d

log_info "dnsmasq 配置完成"

# 步骤 8: 部署 NexusRoute 应用
next_step "部署 NexusRoute 应用"

log_info "创建应用目录..."
mkdir -p /opt/nexusroute/public

log_info "复制应用文件..."
# 注意：这里假设脚本与应用文件在同一目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/server.js" ]; then
    cp "$SCRIPT_DIR/server.js" /opt/nexusroute/
    log_info "server.js 已复制"
else
    log_warn "未找到 server.js，需要手动部署"
fi

if [ -f "$SCRIPT_DIR/package.json" ]; then
    cp "$SCRIPT_DIR/package.json" /opt/nexusroute/
    log_info "package.json 已复制"
fi

if [ -d "$SCRIPT_DIR/public" ]; then
    cp -r "$SCRIPT_DIR/public/"* /opt/nexusroute/public/
    log_info "前端文件已复制"
else
    log_warn "未找到 public 目录，需要手动部署"
fi

# 安装 Node.js 依赖
if [ -f "/opt/nexusroute/package.json" ]; then
    log_info "安装 Node.js 依赖..."
    cd /opt/nexusroute
    npm install --production
    cd -
fi

# 步骤 9: 初始化数据库
next_step "初始化数据库"

log_info "创建数据库..."

# 生成密码哈希（使用 Node.js）
ADMIN_PASSWORD_HASH=$(node -e "
const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const hash = bcrypt.hashSync('$ADMIN_PASSWORD', 10);
console.log(hash);
" 2>/dev/null || echo "")

if [ -z "$ADMIN_PASSWORD_HASH" ]; then
    log_warn "bcryptjs 未安装，使用简单哈希（不推荐用于生产环境）"
    ADMIN_PASSWORD_HASH=$(echo -n "$ADMIN_PASSWORD" | sha256sum | cut -d' ' -f1)
fi

# 创建数据库表
sqlite3 /opt/nexusroute/db.sqlite <<EOF
-- 用户表
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

-- 节点表
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
  enabled BOOLEAN DEFAULT 1,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- 用户路由配置表
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

-- 待审批设备表
CREATE TABLE IF NOT EXISTS pending_devices (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  mac_address TEXT UNIQUE NOT NULL,
  first_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
  last_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
  hostname TEXT,
  status TEXT DEFAULT 'pending'
);

-- 管理员表
CREATE TABLE IF NOT EXISTS admins (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- 插入默认管理员账户
INSERT OR REPLACE INTO admins (id, username, password_hash)
VALUES (1, 'admin', '$ADMIN_PASSWORD_HASH');
EOF

log_info "数据库初始化完成"

# 步骤 10: 配置 systemd 服务
next_step "配置 systemd 服务"

log_info "创建 NexusRoute 服务..."
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

log_info "重载 systemd 配置..."
systemctl daemon-reload

log_info "启用服务..."
systemctl enable nexusroute
systemctl enable dnsmasq

log_info "启动服务..."
systemctl start dnsmasq
systemctl start nexusroute

# 等待服务启动
sleep 3

# 检查服务状态
if systemctl is-active --quiet nexusroute; then
    log_info "NexusRoute 服务启动成功"
else
    log_error "NexusRoute 服务启动失败"
    log_error "请查看日志: journalctl -u nexusroute -n 50"
    exit 1
fi

if systemctl is-active --quiet dnsmasq; then
    log_info "dnsmasq 服务启动成功"
else
    log_error "dnsmasq 服务启动失败"
    log_error "请查看日志: journalctl -u dnsmasq -n 50"
    exit 1
fi

# 配置 iptables 规则
log_info "配置 iptables 规则..."
if [ -f "$SCRIPT_DIR/iptables_rules.sh" ]; then
    cp "$SCRIPT_DIR/iptables_rules.sh" /opt/nexusroute/
    chmod +x /opt/nexusroute/iptables_rules.sh
    /opt/nexusroute/iptables_rules.sh setup
else
    log_warn "未找到 iptables_rules.sh，需要手动配置防火墙规则"
fi

# 安装完成
echo ""
echo "=========================================="
echo -e "${GREEN}NexusRoute 安装完成！${NC}"
echo "=========================================="
echo ""
echo "访问地址："
echo "  - 用户前台: http://192.168.100.1/"
echo "  - 管理后台: http://192.168.100.1/admin"
echo ""
echo "管理员账户："
echo "  - 用户名: admin"
echo "  - 密码: (您刚才设置的密码)"
echo ""
echo "下一步操作："
echo "  1. 访问管理后台添加代理节点"
echo "  2. 连接 Windows 虚拟机到 Nexus_LAN_Isolated 交换机"
echo "  3. Windows 虚拟机将自动获取 IP 并显示在待审批列表"
echo "  4. 在管理后台批准设备后，即可开始使用"
echo ""
echo "防漏油测试："
echo "  在 Ubuntu 执行: systemctl stop xray-user1"
echo "  在 Windows 虚拟机测试: ping 8.8.8.8 (应该超时)"
echo ""
echo "查看服务状态："
echo "  systemctl status nexusroute"
echo "  systemctl status dnsmasq"
echo ""
echo "查看日志："
echo "  journalctl -u nexusroute -f"
echo "  journalctl -u dnsmasq -f"
echo ""
echo "=========================================="
