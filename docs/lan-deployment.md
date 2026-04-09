# NexusRoute 部署指南 - 局域网环境

## 📋 目录

- [环境概述](#环境概述)
- [第一部分：硬件准备](#第一部分硬件准备)
- [第二部分：Ubuntu 系统安装](#第二部分ubuntu-系统安装)
- [第三部分：网络配置](#第三部分网络配置)
- [第四部分：NexusRoute 部署](#第四部分nexusroute-部署)
- [第五部分：客户端接入](#第五部分客户端接入)

---

## 环境概述

### 网络拓扑

```
光猫/路由器 (192.168.1.1)
    │
    ├── 家庭设备 (192.168.1.x)
    │   ├── 电脑
    │   ├── 手机
    │   └── 其他设备
    │
    └── NexusRoute 网关 (物理机/软路由)
        ├── eth0: 192.168.1.100 (连接路由器)
        └── eth1: 192.168.100.1 (内网网关)
            │
            └── 交换机
                ├── 需要代理的电脑
                ├── 需要代理的手机 (通过 AP)
                └── 其他需要代理的设备
```

### 适用场景

| 场景 | 硬件 | 适用人群 |
|------|------|---------|
| 家庭部署 | 闲置电脑/笔记本 | 家庭用户 |
| 软路由 | J1900/N5105 | 发烧友 |
| 工作室 | 服务器/工控机 | 小团队 |
| 测试环境 | 任意双网口设备 | 开发者 |

### 系统要求

- **CPU**：x86_64 架构，双核以上
- **内存**：至少 2GB
- **存储**：至少 20GB
- **网卡**：2 个网口（或 1 个网口 + USB 网卡）
- **系统**：Ubuntu Server 22.04 LTS

---

## 第一部分：硬件准备

### 1.1 选择硬件

#### 方案 A：闲置电脑/笔记本（最简单）

**优点**：
- 成本低（利用闲置设备）
- 性能充足
- 易于调试

**缺点**：
- 功耗较高（约 30-50W）
- 体积较大

**推荐配置**：
```
CPU：Intel i3/i5 或 AMD 同级别
内存：4GB 以上
硬盘：120GB SSD 或 500GB HDD
网卡：板载网卡 + USB 网卡
```

**USB 网卡推荐**：
- 绿联 USB 3.0 千兆网卡（Realtek RTL8153）
- TP-Link UE300（Realtek RTL8153）
- UGREEN USB 网卡（ASIX AX88179）

#### 方案 B：软路由（推荐）

**优点**：
- 功耗低（约 10-15W）
- 体积小
- 多网口

**缺点**：
- 需要购买（约 500-1500 元）

**推荐型号**：
```
入门级：J1900 四网口（500-800 元）
中端：N5105 四网口（800-1200 元）
高端：i5-8250U 六网口（1200-2000 元）
```

**购买渠道**：
- 淘宝/京东搜索"软路由"
- 闲鱼二手市场

#### 方案 C：服务器/工控机（企业级）

**优点**：
- 性能强劲
- 稳定性高
- 可扩展性强

**缺点**：
- 成本高
- 功耗高
- 噪音大

**推荐配置**：
```
CPU：Intel Xeon 或 AMD EPYC
内存：8GB 以上
硬盘：SSD RAID
网卡：双千兆或万兆
```

### 1.2 检查网卡数量

#### 方法一：物理检查

查看设备背面的网口数量：
- **双网口**：直接使用
- **单网口**：需要购买 USB 网卡

#### 方法二：系统检查

**如果已安装 Linux**：
```bash
# 查看网卡列表
ip link show

# 或者
lspci | grep Ethernet
lsusb | grep Ethernet
```

**如果是 Windows**：
```cmd
# 打开设备管理器
devmgmt.msc

# 展开"网络适配器"
# 查看网卡数量
```

### 1.3 准备安装介质

#### 下载 Ubuntu Server 22.04

**官方下载**：
```
https://ubuntu.com/download/server
```

**国内镜像**：
```
清华镜像：https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/22.04/
阿里镜像：https://mirrors.aliyun.com/ubuntu-releases/22.04/
```

**文件名**：
```
ubuntu-22.04.3-live-server-amd64.iso
```

#### 制作启动 U 盘

**Windows**：
1. 下载 Rufus：https://rufus.ie/
2. 插入 U 盘（至少 4GB）
3. 打开 Rufus
4. 选择 ISO 文件
5. 点击"开始"

**macOS**：
1. 下载 balenaEtcher：https://www.balena.io/etcher/
2. 插入 U 盘
3. 打开 Etcher
4. 选择 ISO 文件
5. 点击"Flash"

**Linux**：
```bash
# 查看 U 盘设备名
lsblk

# 写入 ISO（假设 U 盘是 /dev/sdb）
sudo dd if=ubuntu-22.04.3-live-server-amd64.iso of=/dev/sdb bs=4M status=progress
sudo sync
```

---

## 第二部分：Ubuntu 系统安装

### 2.1 BIOS 设置

#### 步骤 1：进入 BIOS

**常见按键**：
- Dell：F2 或 F12
- HP：F10 或 ESC
- Lenovo：F1 或 F2
- 华硕：F2 或 DEL
- 技嘉：DEL

#### 步骤 2：设置启动顺序

1. 找到"Boot"或"启动"选项
2. 将 U 盘设置为第一启动项
3. 保存并退出（通常是 F10）

#### 步骤 3：禁用 Secure Boot（如果需要）

1. 找到"Security"或"安全"选项
2. 找到"Secure Boot"
3. 设置为"Disabled"
4. 保存并退出

### 2.2 安装 Ubuntu

#### 步骤 1：启动安装程序

1. 插入 U 盘
2. 重启电脑
3. 进入 Ubuntu 安装界面

#### 步骤 2：语言和键盘

**语言选择**：
```
English (推荐，避免中文乱码)
```

**键盘布局**：
```
English (US)
```

#### 步骤 3：网络配置（关键！）

你会看到两个网卡（假设是 eth0 和 eth1）：

**识别网卡对应关系**：

⚠️ **重要**：需要确定哪个网卡对应哪个物理接口！

**方法一：拔插网线法**
1. 拔掉所有网线
2. 只插一根网线到第一个网口
3. 看安装界面哪个网卡有 IP
4. 记录：第一个网口 = eth0（或 ens33）

**方法二：MAC 地址法**
1. 在 BIOS 或路由器中查看网卡 MAC 地址
2. 对比安装界面显示的 MAC 地址
3. 确定对应关系

**配置 eth0（外网）**：
```
连接：插网线到路由器
配置：DHCP (自动获取)
```

**配置 eth1（内网）**：
```
连接：暂时不插网线
配置：Manual (手动配置)

Subnet: 192.168.100.0/24
Address: 192.168.100.1
Gateway: 留空
Name servers: 留空
```

⚠️ **避坑**：eth1 必须手动配置，否则会卡住！

#### 步骤 4：其他配置

**代理**：
```
留空
```

**镜像源**：
```
默认（或选择国内镜像）
```

**存储**：
```
使用整个磁盘
```

**用户配置**：
```
用户名：[自定义，例如 admin]
密码：[自定义，建议强密码]
服务器名称：nexusroute
```

**SSH**：
```
✅ 勾选 "Install OpenSSH server"
```

**软件包**：
```
不选择任何额外软件包
```

#### 步骤 5：完成安装

1. 等待安装完成（约 10-20 分钟）
2. 选择"Reboot Now"
3. 拔出 U 盘
4. 重启进入系统

### 2.3 首次登录

#### 步骤 1：登录系统

```
login: admin
password: [你设置的密码]
```

#### 步骤 2：更新系统

```bash
# 更新软件包列表
sudo apt update

# 升级系统
sudo apt upgrade -y

# 重启（如果有内核更新）
sudo reboot
```

#### 步骤 3：验证网络

```bash
# 查看网卡
ip addr show

# 应该看到：
# eth0: 有 IP 地址（例如 192.168.1.100）
# eth1: 192.168.100.1/24

# 测试外网
ping -c 3 8.8.8.8

# 测试 DNS
ping -c 3 google.com
```

---

## 第三部分：网络配置

### 3.1 确认网卡名称

```bash
# 查看网卡列表
ip link show

# 常见网卡名称：
# eth0, eth1 (传统命名)
# ens33, ens34 (新命名规则)
# enp1s0, enp2s0 (PCI 命名)
```

⚠️ **注意**：后续步骤中的 `eth0` 和 `eth1` 需要替换为你的实际网卡名称。

### 3.2 配置 netplan

#### 步骤 1：编辑配置文件

```bash
# 查看现有配置文件
ls /etc/netplan/

# 编辑配置文件（文件名可能不同）
sudo nano /etc/netplan/00-installer-config.yaml
```

#### 步骤 2：配置内容

**模板**：
```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:  # 外网网卡，替换为你的实际名称
      dhcp4: true
    eth1:  # 内网网卡，替换为你的实际名称
      dhcp4: false
      addresses:
        - 192.168.100.1/24
```

**示例（如果网卡名称是 ens33 和 ens34）**：
```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    ens33:
      dhcp4: true
    ens34:
      dhcp4: false
      addresses:
        - 192.168.100.1/24
```

#### 步骤 3：应用配置

```bash
# 测试配置（不会实际应用）
sudo netplan try

# 如果没有错误，按 Enter 确认

# 应用配置
sudo netplan apply

# 验证配置
ip addr show
```

### 3.3 启用 IP 转发

```bash
# 临时启用
sudo sysctl -w net.ipv4.ip_forward=1

# 永久启用
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf

# 应用配置
sudo sysctl -p
```

### 3.4 配置防火墙（可选）

```bash
# 安装 ufw（如果没有）
sudo apt install ufw -y

# 允许 SSH
sudo ufw allow 22/tcp

# 允许内网访问
sudo ufw allow from 192.168.100.0/24

# 启用防火墙
sudo ufw enable

# 查看状态
sudo ufw status
```

---

## 第四部分：NexusRoute 部署

### 4.1 下载项目

```bash
# 安装 git（如果没有）
sudo apt install git -y

# 下载项目
git clone https://github.com/Kxiandaoyan/NexusRoute.git

# 进入项目目录
cd NexusRoute
```

### 4.2 运行安装脚本

```bash
# 添加执行权限
chmod +x install.sh

# 运行安装脚本
sudo ./install.sh
```

**安装过程**：
1. 检查系统环境
2. 检测网卡（eth0 和 eth1）
3. 检查网络连接
4. 输入管理员密码（用于登录管理后台）
5. 安装依赖（Node.js、Xray、dnsmasq）
6. 配置网络
7. 初始化数据库
8. 启动服务

**预计时间**：10-15 分钟

### 4.3 验证安装

```bash
# 检查服务状态
sudo systemctl status nexusroute
sudo systemctl status dnsmasq

# 查看日志
sudo journalctl -u nexusroute -n 50
sudo journalctl -u dnsmasq -n 50

# 测试管理后台
curl http://192.168.100.1/admin
```

### 4.4 访问管理后台

1. 在网关上打开浏览器（如果有桌面环境）
2. 或者在另一台电脑上配置静态 IP（192.168.100.50）
3. 访问 http://192.168.100.1/admin
4. 登录（用户名：admin，密码：安装时设置的）

---

## 第五部分：客户端接入

### 5.1 物理连接

#### 步骤 1：连接交换机

```
NexusRoute eth1 (192.168.100.1)
    │
    └── 交换机
        ├── 电脑 1 (网线)
        ├── 电脑 2 (网线)
        └── 无线 AP (可选)
            ├── 手机 (WiFi)
            └── 平板 (WiFi)
```

**操作步骤**：
1. 用网线连接 NexusRoute 的 eth1 到交换机
2. 用网线连接客户端设备到交换机

#### 步骤 2：配置无线 AP（可选）

如果你想让手机/平板也使用代理：

**购买无线 AP**：
- 推荐：TP-Link、Ubiquiti、华硕
- 模式：AP 模式（非路由模式）
- 价格：100-500 元

**配置步骤**：
1. 将 AP 连接到交换机
2. 登录 AP 管理界面
3. 设置为"AP 模式"或"桥接模式"
4. 关闭 AP 的 DHCP 功能
5. 设置 WiFi 名称和密码
6. 保存并重启

### 5.2 Windows 客户端

#### 自动配置（推荐）

1. 连接网线到交换机
2. 打开"网络和共享中心"
3. 确认"以太网"已连接
4. 等待自动获取 IP（约 10 秒）
5. 打开浏览器访问 http://192.168.100.1/

#### 手动配置（测试用）

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

4. 点击"确定"
5. 打开浏览器访问 http://192.168.100.1/

### 5.3 macOS 客户端

#### 自动配置（推荐）

1. 连接网线到交换机
2. 系统偏好设置 → 网络
3. 选择"以太网"
4. 确认"配置 IPv4：使用 DHCP"
5. 等待自动获取 IP
6. 打开浏览器访问 http://192.168.100.1/

#### 手动配置（测试用）

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

4. 点击"应用"
5. 打开浏览器访问 http://192.168.100.1/

### 5.4 Linux 客户端

#### 自动配置（推荐）

```bash
# 使用 DHCP 获取 IP
sudo dhclient eth0

# 或者使用 NetworkManager
nmcli device connect eth0

# 验证 IP
ip addr show eth0

# 测试连接
ping 192.168.100.1
```

#### 手动配置（测试用）

```bash
# 配置静态 IP
sudo ip addr add 192.168.100.52/24 dev eth0
sudo ip route add default via 192.168.100.1
echo "nameserver 192.168.100.1" | sudo tee /etc/resolv.conf

# 验证配置
ip addr show eth0
ip route show
```

### 5.5 手机/平板客户端

#### Android

1. 连接 WiFi（如果使用无线 AP）
2. 长按 WiFi 名称 → "修改网络"
3. 高级选项 → IP 设置：DHCP
4. 保存
5. 打开浏览器访问 http://192.168.100.1/

#### iOS

1. 连接 WiFi（如果使用无线 AP）
2. 点击 WiFi 名称旁的 (i)
3. 配置 IP：自动
4. 保存
5. 打开浏览器访问 http://192.168.100.1/

### 5.6 设备审批流程

1. 客户端设备连接到交换机
2. 自动获取临时 IP（192.168.100.50-99）
3. 在管理后台（http://192.168.100.1/admin）看到"待审批设备"
4. 点击"批准"
5. 设备重新获取永久 IP（192.168.100.10-209）
6. 访问 http://192.168.100.1/ 选择代理节点

---

## 常见问题

### Q1: 如何确定哪个网卡是 eth0，哪个是 eth1？

A: 使用拔插网线法：
1. 拔掉所有网线
2. 只插一根网线到第一个网口
3. 运行 `ip addr show`
4. 看哪个网卡有 IP 地址
5. 记录对应关系

### Q2: 安装时提示"未检测到两个网卡"？

A: 检查：
1. USB 网卡是否插好
2. 运行 `ip link show` 查看网卡列表
3. 运行 `lsusb` 查看 USB 设备
4. 尝试更换 USB 接口

### Q3: 客户端无法获取 IP？

A: 检查：
1. 网线是否连接到 eth1（内网网卡）
2. eth1 是否配置为 192.168.100.1
3. dnsmasq 服务是否运行：`sudo systemctl status dnsmasq`
4. 防火墙是否阻止 DHCP：`sudo ufw status`

### Q4: 无法访问外网？

A: 检查：
1. eth0 是否有 IP：`ip addr show eth0`
2. 是否能 ping 通网关：`ping 192.168.1.1`
3. 是否能 ping 通外网：`ping 8.8.8.8`
4. IP 转发是否启用：`sysctl net.ipv4.ip_forward`

### Q5: 管理后台无法访问？

A: 检查：
1. nexusroute 服务是否运行：`sudo systemctl status nexusroute`
2. 端口是否监听：`sudo netstat -tlnp | grep 80`
3. 防火墙是否阻止：`sudo ufw status`
4. 客户端 IP 是否正确：`ipconfig` 或 `ip addr`

### Q6: 如何远程管理网关？

A: 两种方法：

**方法一：SSH**
```bash
# 从客户端 SSH 登录网关
ssh admin@192.168.100.1
```

**方法二：从外网 SSH**
```bash
# 在路由器上配置端口转发
# 外网端口 2222 → 192.168.1.100:22

# 从外网登录
ssh -p 2222 admin@[你的公网IP]
```

### Q7: 如何备份配置？

A: 备份数据库文件：
```bash
# 在网关上
sudo cp /opt/nexusroute/db.sqlite /opt/nexusroute/db.sqlite.backup

# 下载到本地
scp admin@192.168.100.1:/opt/nexusroute/db.sqlite.backup ~/Desktop/
```

### Q8: 如何恢复配置？

A: 恢复数据库文件：
```bash
# 上传备份文件
scp ~/Desktop/db.sqlite.backup admin@192.168.100.1:/tmp/

# 在网关上恢复
sudo systemctl stop nexusroute
sudo cp /tmp/db.sqlite.backup /opt/nexusroute/db.sqlite
sudo systemctl start nexusroute
```

---

## 性能优化

### 硬件优化

**SSD 优化**：
```bash
# 启用 TRIM
sudo systemctl enable fstrim.timer
sudo systemctl start fstrim.timer
```

**网卡优化**：
```bash
# 查看网卡参数
ethtool eth0

# 启用网卡 offload 功能
sudo ethtool -K eth0 tso on gso on gro on
sudo ethtool -K eth1 tso on gso on gro on
```

### 系统优化

**内核参数优化**：
```bash
# 编辑 sysctl 配置
sudo nano /etc/sysctl.conf

# 添加以下内容
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_congestion_control = bbr

# 应用配置
sudo sysctl -p
```

**BBR 拥塞控制**：
```bash
# 启用 BBR
echo "net.core.default_qdisc=fq" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# 验证
sysctl net.ipv4.tcp_congestion_control
```

---

## 安全加固

### SSH 安全

```bash
# 编辑 SSH 配置
sudo nano /etc/ssh/sshd_config

# 修改以下内容
Port 2222  # 更改默认端口
PermitRootLogin no  # 禁止 root 登录
PasswordAuthentication yes  # 允许密码登录（或使用密钥）

# 重启 SSH 服务
sudo systemctl restart sshd
```

### 防火墙配置

```bash
# 允许 SSH（新端口）
sudo ufw allow 2222/tcp

# 允许内网访问
sudo ufw allow from 192.168.100.0/24

# 拒绝其他外部访问
sudo ufw default deny incoming
sudo ufw default allow outgoing

# 启用防火墙
sudo ufw enable
```

### 自动更新

```bash
# 安装自动更新
sudo apt install unattended-upgrades -y

# 启用自动更新
sudo dpkg-reconfigure -plow unattended-upgrades
```

---

## 下一步

- [返回主文档](../README.md)
- [查看 Hyper-V 部署指南](hyperv-deployment.md)
- [查看 VMware 部署指南](vmware-deployment.md)
- [查看 NAS 部署指南](nas-deployment.md)

---

**文档版本**：1.0  
**最后更新**：2026-04-10  
**适用环境**：物理机/软路由/服务器
