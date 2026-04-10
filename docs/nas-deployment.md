# NexusRoute 部署指南 - NAS 环境

## 📋 目录

- [环境概述](#环境概述)
- [第一部分：NAS 网络准备](#第一部分nas-网络准备)
- [第二部分：Ubuntu 虚拟机部署](#第二部分ubuntu-虚拟机部署)
- [第三部分：客户端设备配置](#第三部分客户端设备配置)
- [第四部分：验证与测试](#第四部分验证与测试)

---

## 环境概述

### 网络拓扑

```
家庭路由器
    │
    ├── NAS (双网口或单网口+交换机)
    │   ├── eth0: 192.168.1.x (连接路由器)
    │   └── eth1: 192.168.100.1 (内网网关)
    │       │
    │       └── Ubuntu 虚拟机 (NexusRoute)
    │           ├── 桥接到 eth0 (外网)
    │           └── 桥接到 eth1 (内网)
    │
    └── 交换机 (连接到 NAS eth1)
        ├── 电脑
        ├── 手机
        └── 其他设备
```

### 系统要求

- **NAS 型号**：群晖 (Synology)、威联通 (QNAP)、或其他支持虚拟化的 NAS
- **网口要求**：至少 2 个网口（或 1 个网口 + USB 网卡）
- **内存要求**：NAS 至少 4GB 内存（给 Ubuntu 虚拟机分配 2GB）
- **存储空间**：至少 30GB 可用空间

### 支持的 NAS 品牌

| 品牌 | 虚拟化方案 | 推荐型号 |
|------|-----------|---------|
| 群晖 (Synology) | Virtual Machine Manager | DS920+, DS1621+, DS1821+ |
| 威联通 (QNAP) | Virtualization Station | TS-453D, TS-673A, TS-873A |
| 华芸 (Asustor) | VirtualBox | AS5304T, AS6604T |
| 其他 | Docker (受限) | 支持 Docker 的型号 |

---

## 第一部分：NAS 网络准备

### 1.1 确认 NAS 网口数量

#### 方法一：查看 NAS 背面

物理检查 NAS 背面的网口数量：
- **双网口**：最佳方案，直接使用
- **单网口**：需要购买 USB 网卡

#### 方法二：登录 NAS 管理界面

**群晖**：
1. 登录 DSM
2. 控制面板 → 网络 → 网络界面
3. 查看网络接口列表

**威联通**：
1. 登录 QTS
2. 控制台 → 网络与文件服务 → 网络
3. 查看网络接口

### 1.2 配置 NAS 网口

#### 场景 A：双网口 NAS（推荐）

**eth0 (外网)**：
```
连接：路由器
IP 配置：DHCP 或静态 IP (例如 192.168.1.100)
用途：NAS 管理、外网访问
```

**eth1 (内网)**：
```
连接：交换机（连接需要代理的设备）
IP 配置：静态 IP
IP 地址：192.168.100.1
子网掩码：255.255.255.0
默认网关：留空
DNS：留空
```

**群晖配置步骤**：
1. 控制面板 → 网络 → 网络界面
2. 选择 LAN 2 (eth1)
3. 点击"编辑"
4. 选择"使用手动配置"
5. 填写上述参数
6. 点击"确定"

**威联通配置步骤**：
1. 控制台 → 网络与文件服务 → 网络
2. 选择"适配器 2"
3. 点击"编辑"
4. 选择"使用静态 IP"
5. 填写上述参数
6. 点击"应用"

#### 场景 B：单网口 + USB 网卡

**购买 USB 网卡**：
- 推荐芯片：Realtek RTL8153、ASIX AX88179
- 速率：千兆（1000Mbps）
- 接口：USB 3.0

**配置步骤**：
1. 插入 USB 网卡到 NAS
2. 等待 NAS 识别（约 30 秒）
3. 在网络设置中找到新网卡（通常显示为 eth1 或 usb0）
4. 按照"场景 A"配置 eth1

**验证 USB 网卡**：
```bash
# SSH 登录 NAS
ssh admin@192.168.1.100

# 查看网卡
ip link show

# 应该看到 eth1 或 usb0
```

#### 场景 C：单网口 + VLAN（高级）

如果你的交换机支持 VLAN，可以用单网口实现隔离：

**前置条件**：
- 交换机支持 VLAN（802.1Q）
- 了解 VLAN 配置

**配置思路**：
1. 在交换机上创建两个 VLAN（VLAN 1 外网，VLAN 100 内网）
2. NAS 网口配置为 Trunk 模式
3. 在 NAS 上创建 VLAN 子接口

⚠️ **注意**：此方案较复杂，建议使用场景 A 或 B。

### 1.3 验证网络配置

**测试 eth0（外网）**：
```bash
# SSH 登录 NAS
ssh admin@192.168.1.100

# 测试外网
ping -c 3 8.8.8.8
```

**测试 eth1（内网）**：
```bash
# 查看 eth1 配置
ip addr show eth1

# 应该显示 192.168.100.1/24
```

---

## 第二部分：Ubuntu 虚拟机部署

### 2.1 群晖 (Synology) 部署

#### 步骤 1：安装 Virtual Machine Manager

1. 打开"套件中心"
2. 搜索"Virtual Machine Manager"
3. 点击"安装"
4. 等待安装完成

#### 步骤 2：创建虚拟交换机

1. 打开 Virtual Machine Manager
2. 点击左侧"网络" → "虚拟交换机"
3. 点击"新增"

**外部交换机（WAN）**：
```
名称：vSwitch_WAN
类型：外部
连接到：eth0
```

**内部交换机（LAN）**：
```
名称：vSwitch_LAN
类型：外部
连接到：eth1
```

⚠️ **注意**：群晖的"外部"交换机相当于桥接模式。

#### 步骤 3：创建 Ubuntu 虚拟机

1. 点击"虚拟机" → "新增"
2. 选择"Linux"

**配置参数**：
```
名称：NexusRoute-Gateway
ISO 映像：[上传 Ubuntu Server 22.04 ISO]
CPU：2 核
内存：2048 MB
磁盘：20 GB
网络适配器 1：vSwitch_WAN
```

3. 点击"下一步" → "应用"

#### 步骤 4：添加第二个网卡

1. 选中虚拟机，点击"编辑"
2. 点击"网络" → "新增网络适配器"
3. 选择 `vSwitch_LAN`
4. 点击"确定"

#### 步骤 5：安装 Ubuntu

1. 选中虚拟机，点击"开机"
2. 点击"连接"打开控制台
3. 按照 [Ubuntu 安装步骤](#ubuntu-安装步骤) 完成安装

### 2.2 威联通 (QNAP) 部署

#### 步骤 1：启用 Virtualization Station

1. 打开"App Center"
2. 搜索"Virtualization Station"
3. 点击"安装"
4. 等待安装完成

#### 步骤 2：上传 ISO 映像

1. 打开 Virtualization Station
2. 点击"ISO 映像" → "上传"
3. 选择 Ubuntu Server 22.04 ISO
4. 等待上传完成

#### 步骤 3：创建虚拟机

1. 点击"创建虚拟机"
2. 选择"Linux"

**配置参数**：
```
名称：NexusRoute-Gateway
操作系统：Ubuntu 64-bit
CPU：2 核
内存：2048 MB
磁盘：20 GB
网络适配器 1：桥接到 adapter1 (eth0)
网络适配器 2：桥接到 adapter2 (eth1)
ISO 映像：ubuntu-22.04-live-server-amd64.iso
```

3. 点击"创建"

#### 步骤 4：安装 Ubuntu

1. 选中虚拟机，点击"启动"
2. 点击"VNC"打开控制台
3. 按照 [Ubuntu 安装步骤](#ubuntu-安装步骤) 完成安装

### 2.3 Docker 部署（受限方案）

⚠️ **警告**：Docker 方案有限制，不推荐新手使用。

**限制**：
- 需要 `--privileged` 和 `--net=host` 权限
- iptables 规则可能与宿主机冲突
- 性能略低于虚拟机

**仅在以下情况使用**：
- NAS 不支持虚拟化
- 内存不足（Docker 占用更少）

**Docker 部署步骤**：

```bash
# SSH 登录 NAS
ssh admin@192.168.1.100

# 拉取 Ubuntu 镜像
docker pull ubuntu:22.04

# 创建容器
docker run -d \
  --name nexusroute \
  --privileged \
  --net=host \
  --restart=unless-stopped \
  -v /volume1/nexusroute:/opt/nexusroute \
  ubuntu:22.04 \
  /bin/bash -c "apt update && apt install -y systemd && exec /sbin/init"

# 进入容器
docker exec -it nexusroute bash

# 在容器内安装 NexusRoute
git clone https://github.com/Kxiandaoyan/NexusRoute.git
cd NexusRoute
chmod +x install.sh
./install.sh
```

### 2.4 Ubuntu 安装步骤

**语言选择**：
```
English
```

**网络配置**（关键！）：

**网卡 1 (ens18/eth0) - 外网**：
```
配置：DHCP
```

**网卡 2 (ens19/eth1) - 内网**：
```
配置：Manual
Subnet: 192.168.100.0/24
Address: 192.168.100.1
Gateway: 留空
Name servers: 留空
```

⚠️ **避坑**：内网网卡必须手动配置，否则会卡住！

**其他选项**：
```
用户名：[自定义]
密码：[自定义]
SSH：✅ 勾选 "Install OpenSSH server"
```

**完成安装**：
1. 等待安装完成
2. 重启虚拟机
3. 登录系统

---

## 第三部分：客户端设备配置

### 3.1 物理连接

#### 方案 A：交换机连接（推荐）

```
NAS eth1 (192.168.100.1)
    │
    └── 交换机
        ├── 电脑 (网线)
        ├── 笔记本 (网线)
        └── 无线 AP (可选)
            ├── 手机 (WiFi)
            └── 平板 (WiFi)
```

**步骤**：
1. 用网线连接 NAS eth1 到交换机
2. 用网线连接设备到交换机
3. 设备会自动获取 IP（安装 NexusRoute 后）

#### 方案 B：直连单台设备

```
NAS eth1 (192.168.100.1)
    │
    └── 电脑 (网线直连)
```

**步骤**：
1. 用网线直连 NAS eth1 和电脑
2. 电脑会自动获取 IP（安装 NexusRoute 后）

⚠️ **限制**：只能连接一台设备。

#### 方案 C：无线 AP 扩展

如果你想让手机/平板也使用代理：

**购买无线 AP**：
- 推荐：TP-Link、Ubiquiti、华硕
- 模式：AP 模式（非路由模式）

**配置步骤**：
1. 将 AP 连接到交换机
2. 配置 AP 为"AP 模式"或"桥接模式"
3. 关闭 AP 的 DHCP 功能
4. 手机连接 AP 的 WiFi

### 3.2 Windows 设备配置

**自动配置（推荐）**：
1. 连接网线到交换机
2. 等待自动获取 IP
3. 打开浏览器访问 http://192.168.100.1/

**手动配置（测试用）**：
1. 打开"网络和共享中心" → "更改适配器设置"
2. 右键"以太网" → "属性"
3. 双击"Internet 协议版本 4 (TCP/IPv4)"

**配置参数**：
```
IP 地址：192.168.100.50
子网掩码：255.255.255.0
默认网关：192.168.100.1
首选 DNS：192.168.100.1
```

### 3.3 macOS 设备配置

**自动配置（推荐）**：
1. 连接网线到交换机
2. 等待自动获取 IP
3. 打开浏览器访问 http://192.168.100.1/

**手动配置（测试用）**：
1. 系统偏好设置 → 网络
2. 选择"以太网"
3. 配置 IPv4：手动

**配置参数**：
```
IP 地址：192.168.100.51
子网掩码：255.255.255.0
路由器：192.168.100.1
DNS 服务器：192.168.100.1
```

### 3.4 手机/平板配置

**Android**：
1. 连接 WiFi（如果使用无线 AP）
2. 长按 WiFi 名称 → "修改网络"
3. IP 设置：DHCP（自动）
4. 打开浏览器访问 http://192.168.100.1/

**iOS**：
1. 连接 WiFi（如果使用无线 AP）
2. 点击 WiFi 名称旁的 (i)
3. 配置 IP：自动
4. 打开浏览器访问 http://192.168.100.1/

---

## 第四部分：验证与测试

### 4.1 网络连通性测试

#### 在 NAS 上测试

**群晖**：
```bash
# SSH 登录 NAS
ssh admin@192.168.1.100

# 测试 eth0（外网）
ping -c 3 8.8.8.8

# 测试 eth1（内网）
ip addr show eth1
# 应该显示 192.168.100.1/24
```

**威联通**：
```bash
# SSH 登录 NAS
ssh admin@192.168.1.100

# 测试 adapter1（外网）
ping -c 3 8.8.8.8

# 测试 adapter2（内网）
ip addr show adapter2
# 应该显示 192.168.100.1/24
```

#### 在 Ubuntu 虚拟机上测试

```bash
# SSH 登录虚拟机
ssh user@192.168.100.1

# 测试外网
ping -c 3 8.8.8.8

# 测试内网接口
ip addr show eth1
# 应该显示 192.168.100.1/24
```

#### 在客户端设备上测试

```bash
# Windows
ping 192.168.100.1
ipconfig /all

# macOS/Linux
ping -c 3 192.168.100.1
ifconfig
```

### 4.2 安装 NexusRoute

在 Ubuntu 虚拟机中执行：

```bash
# 下载项目
git clone https://github.com/Kxiandaoyan/NexusRoute.git
cd NexusRoute

# 运行安装脚本
chmod +x install.sh
sudo ./install.sh
```

安装完成后：
- 管理后台：http://192.168.100.1/admin
- 用户前台：http://192.168.100.1/

### 4.3 设备自动注册流程

1. 客户端设备连接到交换机
2. 自动获取永久 IP（192.168.100.10-209，无限期租约）
3. 设备自动注册到系统，约 15 秒内完成
4. 直接访问 http://192.168.100.1/ 选择代理

### 4.4 防漏油测试

```bash
# 在 Ubuntu 虚拟机上停止代理
sudo systemctl stop xray-user1

# 在客户端设备上测试
ping 8.8.8.8
# 应该超时（无法连接）

# 恢复代理
sudo systemctl start xray-user1
```

---

## 常见问题

### Q1: NAS 只有一个网口怎么办？

A: 购买 USB 千兆网卡（推荐 Realtek RTL8153 芯片），按照 [场景 B](#场景-b单网口--usb-网卡) 配置。

### Q2: Virtual Machine Manager 无法安装？

A: 检查：
1. NAS 型号是否支持虚拟化（查看官网规格）
2. DSM 版本是否为 7.0 以上
3. CPU 是否支持虚拟化（Intel VT-x 或 AMD-V）

### Q3: 虚拟机无法启动？

A: 检查：
1. NAS 内存是否充足（至少 4GB）
2. 存储空间是否充足（至少 30GB）
3. 查看虚拟机日志（Virtual Machine Manager → 虚拟机 → 日志）

### Q4: 客户端设备无法获取 IP？

A: 检查：
1. eth1 是否配置为 192.168.100.1
2. 交换机是否正常工作
3. 网线是否连接正确
4. dnsmasq 服务是否运行：`sudo systemctl status dnsmasq`

### Q5: 性能不足怎么办？

A: 优化建议：
1. 增加虚拟机内存（4GB）
2. 使用 SSD 存储虚拟机磁盘
3. 升级 NAS 网卡到 2.5G 或 10G
4. 减少同时使用代理的设备数量

### Q6: 如何备份配置？

A: 备份以下文件：
```bash
# 在 Ubuntu 虚拟机中
sudo cp /opt/nexusroute/db.sqlite /opt/nexusroute/db.sqlite.backup

# 下载到本地
scp user@192.168.100.1:/opt/nexusroute/db.sqlite.backup ~/Desktop/
```

### Q7: Docker 方案和虚拟机方案有什么区别？

A: 
| 特性 | 虚拟机 | Docker |
|------|--------|--------|
| 隔离性 | 完全隔离 | 共享内核 |
| 性能 | 略低 | 略高 |
| 稳定性 | 更稳定 | 可能冲突 |
| 内存占用 | 2GB+ | 500MB+ |
| 推荐度 | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ |

---

## NAS 特定优化

### 群晖优化

**启用 SSH**：
1. 控制面板 → 终端机和 SNMP
2. 勾选"启动 SSH 功能"
3. 端口：22

**性能优化**：
1. 控制面板 → 硬件和电源 → 常规
2. 启用"网络唤醒"
3. 禁用"硬盘休眠"（避免虚拟机卡顿）

**自动启动虚拟机**：
1. Virtual Machine Manager → 虚拟机
2. 右键虚拟机 → "编辑"
3. 勾选"开机时自动启动"

### 威联通优化

**启用 SSH**：
1. 控制台 → 网络与文件服务 → Telnet/SSH
2. 勾选"允许 SSH 连接"
3. 端口：22

**性能优化**：
1. 控制台 → 系统 → 硬件
2. 禁用"硬盘待机"

**自动启动虚拟机**：
1. Virtualization Station → 虚拟机
2. 右键虚拟机 → "设置"
3. 勾选"NAS 启动时自动启动"

---

## 下一步

- [返回主文档](../README.md)
- [查看 Hyper-V 部署指南](hyperv-deployment.md)
- [查看 VMware 部署指南](vmware-deployment.md)
- [查看局域网部署指南](lan-deployment.md)

---

**文档版本**：1.0  
**最后更新**：2026-04-10  
**适用环境**：群晖/威联通/华芸 NAS
