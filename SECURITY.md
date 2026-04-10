# NexusRoute 安全机制说明

## 核心原则：安全第一

NexusRoute 采用**多层 Kill Switch 机制**，确保任何不能通过代理的流量都会被完全阻止，绝不泄露真实 IP。

---

## 一、流量处理规则

### ✅ 允许通过代理的流量

1. **TCP 流量**
   - 通过 TPROXY 劫持
   - 强制经过 Xray 代理
   - 出口 IP = 代理节点 IP

2. **UDP 流量**（除 DHCP）
   - 通过 TPROXY 劫持
   - 强制经过 Xray 代理
   - 包括：DNS、QUIC、游戏、视频通话等
   - 出口 IP = 代理节点 IP

3. **DNS 查询**
   - UDP 53 和 TCP 53 都被劫持
   - 通过代理节点查询
   - 防止 DNS 泄露

### ❌ 完全阻止的流量（Kill Switch）

1. **ICMP 流量**
   - ping、traceroute 等
   - 原因：代理协议不支持 ICMP
   - 行为：直接 DROP，不转发

2. **其他协议**
   - GRE、ESP、AH、SCTP 等
   - 原因：代理协议不支持
   - 行为：直接 DROP，不转发

3. **DHCP 客户端流量**（UDP 67/68）
   - 仅用于获取 IP 地址
   - 不转发到外网

---

## 二、多层 Kill Switch 机制

### 第一层：FORWARD 链默认 DROP

```bash
iptables -P FORWARD DROP
```

**作用**：
- 默认拒绝所有转发流量
- 只有明确允许的流量才能通过
- 这是最后一道防线

### 第二层：明确阻止 ICMP（FORWARD 链）

```bash
iptables -A FORWARD -i eth1 -p icmp -j DROP \
    -m comment --comment "Kill Switch: Block ICMP forwarding"
```

**作用**：
- 在 FORWARD 链明确阻止 ICMP
- 防止任何 ICMP 流量泄露
- 双重保险

### 第三层：明确阻止其他协议（FORWARD 链）

```bash
iptables -A FORWARD -i eth1 ! -p tcp ! -p udp -j DROP \
    -m comment --comment "Kill Switch: Block non-TCP/UDP forwarding"
```

**作用**：
- 只允许 TCP 和 UDP 转发
- 阻止所有其他协议（GRE、ESP、AH、SCTP 等）
- 双重保险

### 第四层：用户级 ICMP 阻止（PREROUTING 链）

```bash
iptables -t mangle -A PREROUTING -i eth1 \
    -s ${USER_IP} \
    -p icmp \
    -j DROP \
    -m comment --comment "user${USER_ID}: Block ICMP (Kill Switch)"
```

**作用**：
- 在 mangle 表 PREROUTING 链提前阻止
- 针对每个用户的 IP 单独阻止
- 三重保险

### 第五层：用户级其他协议阻止（PREROUTING 链）

```bash
iptables -t mangle -A PREROUTING -i eth1 \
    -s ${USER_IP} \
    ! -p tcp \
    ! -p udp \
    ! -p icmp \
    -j DROP \
    -m comment --comment "user${USER_ID}: Block other protocols (Kill Switch)"
```

**作用**：
- 在 mangle 表 PREROUTING 链提前阻止
- 针对每个用户的 IP 单独阻止
- 三重保险

---

## 三、安全验证

### 验证 TCP 流量走代理

```bash
# 在客户端设备上
curl https://api.ipify.org
# 应该显示代理节点的 IP，而不是真实 IP
```

### 验证 UDP 流量走代理

```bash
# 测试 DNS（UDP）
nslookup google.com 8.8.8.8
# DNS 查询会通过代理节点

# 测试 QUIC（UDP）
curl --http3 https://cloudflare-quic.com/
# 应该显示代理节点的 IP
```

### 验证 ICMP 被阻止（Kill Switch）

```bash
# 在客户端设备上
ping 8.8.8.8
# 应该超时失败，不会有任何响应
# 这是正常的安全行为，证明 Kill Switch 工作正常
```

### 验证代理断开时的行为

```bash
# 在网关上停止代理
sudo systemctl stop xray-user1

# 在客户端设备上测试
curl https://api.ipify.org
# 应该超时失败，不会显示真实 IP

ping 8.8.8.8
# 应该超时失败

# 这证明 Kill Switch 工作正常，代理断开 = 完全断网
```

---

## 四、流量路径图

### TCP/UDP 流量（正常）

```
客户端设备
    ↓
eth1 (192.168.100.0/24)
    ↓
iptables mangle PREROUTING
    ├─ MAC-IP 验证（防欺骗）
    ├─ 打标记（fwmark）
    └─ TPROXY 劫持
        ↓
    Xray 实例（dokodemo-door）
        ↓
    代理节点（第一跳 → 第二跳 → 第三跳）
        ↓
    目标网站
        ↓
    返回：出口 IP = 最后一跳节点 IP ✅
```

### ICMP 流量（被阻止）

```
客户端设备
    ↓
eth1 (192.168.100.0/24)
    ↓
iptables mangle PREROUTING
    ├─ 检测到 ICMP 协议
    └─ DROP（第一层 Kill Switch）❌
        ↓
    （如果漏过）iptables FORWARD
        ├─ 检测到 ICMP 协议
        └─ DROP（第二层 Kill Switch）❌
            ↓
        （如果漏过）默认策略
            └─ DROP（第三层 Kill Switch）❌

结果：ICMP 流量被完全阻止，不会泄露真实 IP ✅
```

### 其他协议流量（被阻止）

```
客户端设备
    ↓
eth1 (192.168.100.0/24)
    ↓
iptables mangle PREROUTING
    ├─ 检测到非 TCP/UDP/ICMP 协议
    └─ DROP（第一层 Kill Switch）❌
        ↓
    （如果漏过）iptables FORWARD
        ├─ 检测到非 TCP/UDP 协议
        └─ DROP（第二层 Kill Switch）❌
            ↓
        （如果漏过）默认策略
            └─ DROP（第三层 Kill Switch）❌

结果：其他协议流量被完全阻止，不会泄露真实 IP ✅
```

---

## 五、其他安全机制

### 1. MAC-IP 双重绑定

```bash
iptables -t mangle -A PREROUTING -i eth1 \
    -s ${USER_IP} \
    -m mac ! --mac-source ${USER_MAC} \
    -j DROP
```

**作用**：
- 防止 IP 欺骗攻击
- 如果 IP 和 MAC 不匹配，直接 DROP
- 确保每个设备只能使用分配的 IP

### 2. 节点层级隔离

- 第一跳节点只能用作第一跳
- 第二跳节点只能用作第二跳
- 第三跳节点只能用作第三跳
- 防止节点混用导致的关联性暴露

### 3. 多实例隔离

- 每个用户独立的 Xray 进程
- 独立的端口、mark、路由表
- 用户之间完全隔离，互不影响

---

## 六、常见问题

### Q1: 为什么 ping 不通？

A: 这是正常的安全行为。ICMP 不能通过代理，为了防止 IP 泄露，系统会完全阻止 ICMP 流量。

### Q2: 如何测试代理是否工作？

A: 使用 TCP/UDP 协议测试：
```bash
curl https://api.ipify.org  # 应该显示代理节点 IP
```

### Q3: 代理断开会泄露真实 IP 吗？

A: 不会。Kill Switch 机制会在代理断开时立即切断所有网络连接，不会泄露真实 IP。

### Q4: 游戏（UDP）能正常工作吗？

A: 可以。UDP 流量会通过 TPROXY 劫持并经过代理，游戏可以正常使用。

### Q5: DNS 会泄露吗？

A: 不会。DNS 查询（UDP 53 和 TCP 53）都会被劫持并通过代理节点查询。

---

## 七、安全等级总结

| 流量类型 | 处理方式 | 安全等级 | 说明 |
|---------|---------|---------|------|
| TCP | TPROXY → 代理 | ✅ 完全安全 | 强制走代理，出口 IP = 代理节点 |
| UDP（非 DHCP）| TPROXY → 代理 | ✅ 完全安全 | 强制走代理，出口 IP = 代理节点 |
| DNS | TPROXY → 代理 | ✅ 完全安全 | 防止 DNS 泄露 |
| ICMP | DROP（三层 Kill Switch）| ✅ 完全安全 | 不泄露真实 IP |
| 其他协议 | DROP（三层 Kill Switch）| ✅ 完全安全 | 不泄露真实 IP |
| DHCP | 本地处理 | ✅ 完全安全 | 仅用于获取 IP，不转发 |

---

## 八、结论

NexusRoute 采用**三层 Kill Switch 机制**，确保：

1. ✅ TCP/UDP 流量 100% 通过代理
2. ✅ DNS 查询 100% 通过代理
3. ✅ ICMP 和其他协议 100% 被阻止
4. ✅ 代理断开 = 完全断网
5. ✅ 绝不泄露真实 IP

**安全第一，安全第一，安全第一！**
