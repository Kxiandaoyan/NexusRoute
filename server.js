const express = require('express');
const jwt = require('jsonwebtoken');
const bcrypt = require('bcryptjs');
const Database = require('better-sqlite3');
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');
const crypto = require('crypto');

const app = express();
const PORT = 80;
const JWT_SECRET = crypto.randomBytes(32).toString('hex');
const DB_PATH = path.join(__dirname, 'db.sqlite');

// 中间件
app.use(express.json());
app.use(express.static('public'));

// 数据库连接
const db = new Database(DB_PATH);
db.pragma('journal_mode = WAL');

// ==================== 工具函数 ====================

// 执行系统命令
function execCommand(command) {
    return new Promise((resolve, reject) => {
        exec(command, (error, stdout, stderr) => {
            if (error) {
                reject({ error, stderr });
            } else {
                resolve(stdout);
            }
        });
    });
}

// MAC地址转IP（哈希算法）
function macToIP(macAddress) {
    const hash = crypto.createHash('md5').update(macAddress).digest('hex');
    const offset = parseInt(hash.substring(0, 2), 16) % 200;
    const ip = `192.168.100.${10 + offset}`;

    // 检查IP是否已被占用
    const existing = db.prepare('SELECT id FROM users WHERE ip_address = ?').get(ip);
    if (existing) {
        // 查找下一个可用IP
        for (let i = 10; i <= 209; i++) {
            const testIP = `192.168.100.${i}`;
            const exists = db.prepare('SELECT id FROM users WHERE ip_address = ?').get(testIP);
            if (!exists) {
                return testIP;
            }
        }
        throw new Error('IP池已满');
    }

    return ip;
}

// 获取下一个可用端口
function getNextPort() {
    const lastUser = db.prepare('SELECT MAX(xray_port) as max_port FROM users').get();
    return lastUser.max_port ? lastUser.max_port + 1 : 12345;
}

// 获取下一个可用mark
function getNextMark() {
    const lastUser = db.prepare('SELECT MAX(iptables_mark) as max_mark FROM users').get();
    return lastUser.max_mark ? lastUser.max_mark + 1 : 1;
}

// 生成Xray配置
function generateXrayConfig(userId, nodes) {
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
    if (!user) throw new Error('用户不存在');

    const outbounds = [];

    // 生成每一跳的配置
    nodes.forEach((node, index) => {
        const tag = `hop${index + 1}`;
        const outbound = {
            tag: tag,
            protocol: node.protocol
        };

        // 根据协议类型配置
        switch (node.protocol) {
            case 'vmess':
                outbound.settings = {
                    vnext: [{
                        address: node.address,
                        port: node.port,
                        users: [{
                            id: node.uuid,
                            alterId: node.alter_id || 0,
                            security: node.encryption || 'auto'
                        }]
                    }]
                };
                break;

            case 'vless':
                outbound.settings = {
                    vnext: [{
                        address: node.address,
                        port: node.port,
                        users: [{
                            id: node.uuid,
                            encryption: node.encryption || 'none',
                            flow: node.flow || ''
                        }]
                    }]
                };
                break;

            case 'trojan':
                outbound.settings = {
                    servers: [{
                        address: node.address,
                        port: node.port,
                        password: node.password
                    }]
                };
                break;

            case 'shadowsocks':
            case 'ss':
                outbound.settings = {
                    servers: [{
                        address: node.address,
                        port: node.port,
                        method: node.encryption || 'aes-256-gcm',
                        password: node.password
                    }]
                };
                break;

            case 'socks':
                outbound.settings = {
                    servers: [{
                        address: node.address,
                        port: node.port,
                        users: node.password ? [{
                            user: 'user',
                            pass: node.password
                        }] : []
                    }]
                };
                break;
        }

        // 配置传输层
        outbound.streamSettings = {
            network: node.network || 'tcp'
        };

        // TLS配置
        if (node.tls === 'tls' || node.tls === 'xtls') {
            outbound.streamSettings.security = node.tls;
            const tlsSettings = {
                serverName: node.sni || node.address
            };

            if (node.alpn) {
                tlsSettings.alpn = node.alpn.split(',');
            }

            if (node.fingerprint) {
                tlsSettings.fingerprint = node.fingerprint;
            }

            outbound.streamSettings[node.tls === 'xtls' ? 'xtlsSettings' : 'tlsSettings'] = tlsSettings;
        }

        // WebSocket配置
        if (node.network === 'ws') {
            outbound.streamSettings.wsSettings = {
                path: node.ws_path || '/',
                headers: node.ws_host ? { Host: node.ws_host } : {}
            };
        }

        // gRPC配置
        if (node.network === 'grpc') {
            outbound.streamSettings.grpcSettings = {
                serviceName: node.grpc_service_name || '',
                multiMode: node.grpc_mode === 'multi'
            };
        }

        // 级联配置（如果不是最后一跳）
        if (index < nodes.length - 1) {
            outbound.proxySettings = {
                tag: `hop${index + 2}`
            };
        }

        outbounds.push(outbound);
    });

    // 完整配置
    const config = {
        log: {
            loglevel: 'warning'
        },
        inbounds: [
            {
                tag: 'tproxy-in',
                port: user.xray_port,
                protocol: 'dokodemo-door',
                settings: {
                    network: 'tcp,udp',
                    followRedirect: true
                },
                streamSettings: {
                    sockopt: {
                        tproxy: 'tproxy',
                        mark: user.iptables_mark
                    }
                }
            },
            {
                tag: 'dns-in',
                port: 5353,
                protocol: 'dokodemo-door',
                settings: {
                    address: '1.1.1.1',
                    port: 53,
                    network: 'tcp,udp'
                }
            }
        ],
        outbounds: outbounds,
        routing: {
            domainStrategy: 'AsIs',
            rules: [
                {
                    type: 'field',
                    inboundTag: ['dns-in'],
                    outboundTag: 'hop1'
                },
                {
                    type: 'field',
                    inboundTag: ['tproxy-in'],
                    outboundTag: 'hop1'
                }
            ]
        }
    };

    return config;
}

// 创建Xray systemd服务
async function createXrayService(userId) {
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
    if (!user) throw new Error('用户不存在');

    const serviceName = `xray-${user.name}`;
    const configPath = `/usr/local/etc/xray/config-${user.name}.json`;

    const serviceContent = `[Unit]
Description=Xray Service for ${user.name}
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/xray run -config ${configPath}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
`;

    fs.writeFileSync(`/etc/systemd/system/${serviceName}.service`, serviceContent);

    await execCommand('systemctl daemon-reload');
    await execCommand(`systemctl enable ${serviceName}`);

    return serviceName;
}

// 更新用户的Xray配置并重启
async function updateUserXray(userId) {
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
    if (!user) throw new Error('用户不存在');

    const route = db.prepare('SELECT * FROM user_routes WHERE user_id = ?').get(userId);
    if (!route) {
        console.log(`用户 ${user.name} 没有配置路由`);
        return;
    }

    // 获取节点信息
    const nodes = [];
    if (route.node1_id) {
        const node1 = db.prepare('SELECT * FROM nodes WHERE id = ?').get(route.node1_id);
        if (node1) nodes.push(node1);
    }
    if (route.node2_id) {
        const node2 = db.prepare('SELECT * FROM nodes WHERE id = ?').get(route.node2_id);
        if (node2) nodes.push(node2);
    }
    if (route.node3_id) {
        const node3 = db.prepare('SELECT * FROM nodes WHERE id = ?').get(route.node3_id);
        if (node3) nodes.push(node3);
    }

    if (nodes.length === 0) {
        throw new Error('没有有效的节点配置');
    }

    // 生成配置
    const config = generateXrayConfig(userId, nodes);
    const configPath = `/usr/local/etc/xray/config-${user.name}.json`;

    fs.writeFileSync(configPath, JSON.stringify(config, null, 2));

    // 重启服务
    const serviceName = `xray-${user.name}`;
    try {
        await execCommand(`systemctl restart ${serviceName}`);
    } catch (error) {
        console.error(`重启 ${serviceName} 失败:`, error);
        throw error;
    }
}

// 添加iptables规则
async function addIptablesRule(userId) {
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
    if (!user) throw new Error('用户不存在');

    const scriptPath = path.join(__dirname, 'iptables_rules.sh');
    if (fs.existsSync(scriptPath)) {
        await execCommand(`${scriptPath} add-user ${user.id} ${user.ip_address} ${user.mac_address} ${user.xray_port}`);
    }
}

// 监控dnsmasq leases文件
function monitorNewDevices() {
    const leasesPath = '/var/lib/misc/dnsmasq.leases';

    setInterval(() => {
        if (!fs.existsSync(leasesPath)) return;

        const content = fs.readFileSync(leasesPath, 'utf8');
        const lines = content.trim().split('\n');

        lines.forEach(line => {
            const parts = line.split(' ');
            if (parts.length < 5) return;

            const [timestamp, mac, ip, hostname] = [parts[0], parts[1], parts[2], parts[3]];

            // 检查是否是临时IP（50-99范围）
            const ipNum = parseInt(ip.split('.')[3]);
            if (ipNum < 50 || ipNum > 99) return;

            // 检查是否已存在
            const existingUser = db.prepare('SELECT id FROM users WHERE mac_address = ?').get(mac);
            const existingPending = db.prepare('SELECT id FROM pending_devices WHERE mac_address = ?').get(mac);

            if (!existingUser && !existingPending) {
                // 添加到待审批列表
                db.prepare(`
                    INSERT INTO pending_devices (mac_address, hostname, status)
                    VALUES (?, ?, 'pending')
                `).run(mac, hostname || 'Unknown');

                console.log(`检测到新设备: ${mac} (${hostname})`);
            } else if (existingPending) {
                // 更新最后见到时间
                db.prepare('UPDATE pending_devices SET last_seen = CURRENT_TIMESTAMP WHERE mac_address = ?').run(mac);
            }
        });
    }, 30000); // 每30秒检查一次
}

// ==================== JWT中间件 ====================

function authenticateToken(req, res, next) {
    const authHeader = req.headers['authorization'];
    const token = authHeader && authHeader.split(' ')[1];

    if (!token) {
        return res.status(401).json({ success: false, message: '未提供认证令牌' });
    }

    jwt.verify(token, JWT_SECRET, (err, user) => {
        if (err) {
            return res.status(403).json({ success: false, message: '令牌无效或已过期' });
        }
        req.user = user;
        next();
    });
}

// ==================== API路由 ====================

// 管理员登录
app.post('/api/admin/login', (req, res) => {
    const { username, password } = req.body;

    if (!username || !password) {
        return res.status(400).json({ success: false, message: '用户名和密码不能为空' });
    }

    const admin = db.prepare('SELECT * FROM admins WHERE username = ?').get(username);

    if (!admin) {
        return res.status(401).json({ success: false, message: '用户名或密码错误' });
    }

    // 验证密码
    let passwordValid = false;
    try {
        passwordValid = bcrypt.compareSync(password, admin.password_hash);
    } catch (error) {
        // 如果不是bcrypt哈希，尝试简单哈希比较
        const simpleHash = crypto.createHash('sha256').update(password).digest('hex');
        passwordValid = admin.password_hash === simpleHash;
    }

    if (!passwordValid) {
        return res.status(401).json({ success: false, message: '用户名或密码错误' });
    }

    // 生成JWT
    const token = jwt.sign({ username: admin.username }, JWT_SECRET, { expiresIn: '24h' });

    res.json({ success: true, token });
});

// 获取所有节点
app.get('/api/admin/nodes', authenticateToken, (req, res) => {
    const nodes = db.prepare('SELECT * FROM nodes ORDER BY id DESC').all();
    res.json({ success: true, nodes });
});

// 添加节点
app.post('/api/admin/nodes', authenticateToken, (req, res) => {
    const node = req.body;

    try {
        const result = db.prepare(`
            INSERT INTO nodes (
                name, protocol, address, port, uuid, alter_id, password,
                encryption, network, tls, sni, alpn, fingerprint,
                ws_path, ws_host, grpc_service_name, grpc_mode, flow, remarks
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        `).run(
            node.name, node.protocol, node.address, node.port,
            node.uuid || null, node.alter_id || 0, node.password || null,
            node.encryption || 'auto', node.network || 'tcp',
            node.tls || 'none', node.sni || null, node.alpn || null,
            node.fingerprint || null, node.ws_path || null, node.ws_host || null,
            node.grpc_service_name || null, node.grpc_mode || 'gun',
            node.flow || null, node.remarks || null
        );

        res.json({ success: true, id: result.lastInsertRowid });
    } catch (error) {
        res.status(500).json({ success: false, message: error.message });
    }
});

// 更新节点
app.put('/api/admin/nodes/:id', authenticateToken, (req, res) => {
    const { id } = req.params;
    const node = req.body;

    try {
        db.prepare(`
            UPDATE nodes SET
                name = ?, protocol = ?, address = ?, port = ?, uuid = ?,
                alter_id = ?, password = ?, encryption = ?, network = ?,
                tls = ?, sni = ?, alpn = ?, fingerprint = ?,
                ws_path = ?, ws_host = ?, grpc_service_name = ?,
                grpc_mode = ?, flow = ?, remarks = ?, enabled = ?
            WHERE id = ?
        `).run(
            node.name, node.protocol, node.address, node.port, node.uuid || null,
            node.alter_id || 0, node.password || null, node.encryption || 'auto',
            node.network || 'tcp', node.tls || 'none', node.sni || null,
            node.alpn || null, node.fingerprint || null, node.ws_path || null,
            node.ws_host || null, node.grpc_service_name || null,
            node.grpc_mode || 'gun', node.flow || null, node.remarks || null,
            node.enabled ? 1 : 0, id
        );

        res.json({ success: true });
    } catch (error) {
        res.status(500).json({ success: false, message: error.message });
    }
});

// 删除节点
app.delete('/api/admin/nodes/:id', authenticateToken, (req, res) => {
    const { id } = req.params;

    try {
        db.prepare('DELETE FROM nodes WHERE id = ?').run(id);
        res.json({ success: true });
    } catch (error) {
        res.status(500).json({ success: false, message: error.message });
    }
});

// 获取待审批设备
app.get('/api/admin/pending-devices', authenticateToken, (req, res) => {
    const devices = db.prepare(`
        SELECT * FROM pending_devices
        WHERE status = 'pending'
        ORDER BY first_seen DESC
    `).all();

    res.json({ success: true, devices });
});

// 批准设备
app.post('/api/admin/approve-device/:id', authenticateToken, async (req, res) => {
    const { id } = req.params;

    try {
        const device = db.prepare('SELECT * FROM pending_devices WHERE id = ?').get(id);
        if (!device) {
            return res.status(404).json({ success: false, message: '设备不存在' });
        }

        // 生成用户信息
        const ip = macToIP(device.mac_address);
        const port = getNextPort();
        const mark = getNextMark();
        const userCount = db.prepare('SELECT COUNT(*) as count FROM users').get().count;
        const userName = `user${userCount + 1}`;

        // 创建用户
        const result = db.prepare(`
            INSERT INTO users (name, mac_address, ip_address, xray_port, iptables_mark)
            VALUES (?, ?, ?, ?, ?)
        `).run(userName, device.mac_address, ip, port, mark);

        const userId = result.lastInsertRowid;

        // 更新设备状态
        db.prepare('UPDATE pending_devices SET status = ? WHERE id = ?').run('approved', id);

        // 添加dnsmasq静态绑定
        const dhcpConfig = `dhcp-host=${device.mac_address},${ip},${userName},infinite\n`;
        fs.appendFileSync('/etc/dnsmasq.d/static-hosts.conf', dhcpConfig);

        // 重启dnsmasq
        await execCommand('systemctl restart dnsmasq');

        // 创建Xray服务
        await createXrayService(userId);

        // 添加iptables规则
        await addIptablesRule(userId);

        res.json({
            success: true,
            user: {
                id: userId,
                name: userName,
                ip_address: ip,
                mac_address: device.mac_address
            }
        });
    } catch (error) {
        console.error('批准设备失败:', error);
        res.status(500).json({ success: false, message: error.message });
    }
});

// 获取所有用户
app.get('/api/admin/users', authenticateToken, (req, res) => {
    const users = db.prepare('SELECT * FROM users ORDER BY id').all();
    res.json({ success: true, users });
});

// 全局重启所有Xray实例
app.post('/api/admin/restart-all', authenticateToken, async (req, res) => {
    try {
        const users = db.prepare('SELECT * FROM users WHERE enabled = 1').all();

        for (const user of users) {
            const serviceName = `xray-${user.name}`;
            try {
                await execCommand(`systemctl restart ${serviceName}`);
            } catch (error) {
                console.error(`重启 ${serviceName} 失败:`, error);
            }
        }

        res.json({ success: true, message: '所有代理实例已重启' });
    } catch (error) {
        res.status(500).json({ success: false, message: error.message });
    }
});

// 用户获取状态（根据IP识别）
app.get('/api/user/status', (req, res) => {
    const clientIP = req.ip.replace('::ffff:', '');

    const user = db.prepare('SELECT * FROM users WHERE ip_address = ?').get(clientIP);

    if (!user) {
        return res.json({
            success: true,
            ip: clientIP,
            status: 'unauthorized',
            message: '设备未授权，请等待管理员批准'
        });
    }

    // 检查Xray服务状态
    const serviceName = `xray-${user.name}`;
    exec(`systemctl is-active ${serviceName}`, (error, stdout) => {
        const isActive = stdout.trim() === 'active';

        // 获取当前路由配置
        const route = db.prepare('SELECT * FROM user_routes WHERE user_id = ?').get(user.id);
        let currentRoute = null;
        let exitIP = null;

        if (route) {
            const nodes = {};
            if (route.node1_id) {
                const node1 = db.prepare('SELECT * FROM nodes WHERE id = ?').get(route.node1_id);
                if (node1) {
                    nodes.node1 = node1.name;
                    exitIP = node1.address;
                }
            }
            if (route.node2_id) {
                const node2 = db.prepare('SELECT * FROM nodes WHERE id = ?').get(route.node2_id);
                if (node2) {
                    nodes.node2 = node2.name;
                    exitIP = node2.address;
                }
            }
            if (route.node3_id) {
                const node3 = db.prepare('SELECT * FROM nodes WHERE id = ?').get(route.node3_id);
                if (node3) {
                    nodes.node3 = node3.name;
                    exitIP = node3.address;
                }
            }
            currentRoute = nodes;
        }

        res.json({
            success: true,
            ip: clientIP,
            status: isActive ? 'online' : 'offline',
            exit_ip: exitIP,
            current_route: currentRoute
        });
    });
});

// 用户设置路由
app.post('/api/user/set-route', async (req, res) => {
    const clientIP = req.ip.replace('::ffff:', '');
    const { node1_id, node2_id, node3_id } = req.body;

    if (!node1_id) {
        return res.status(400).json({ success: false, message: '第一跳节点不能为空' });
    }

    try {
        const user = db.prepare('SELECT * FROM users WHERE ip_address = ?').get(clientIP);

        if (!user) {
            return res.status(403).json({ success: false, message: '设备未授权' });
        }

        // 更新或插入路由配置
        const existing = db.prepare('SELECT id FROM user_routes WHERE user_id = ?').get(user.id);

        if (existing) {
            db.prepare(`
                UPDATE user_routes
                SET node1_id = ?, node2_id = ?, node3_id = ?, updated_at = CURRENT_TIMESTAMP
                WHERE user_id = ?
            `).run(node1_id, node2_id || null, node3_id || null, user.id);
        } else {
            db.prepare(`
                INSERT INTO user_routes (user_id, node1_id, node2_id, node3_id)
                VALUES (?, ?, ?, ?)
            `).run(user.id, node1_id, node2_id || null, node3_id || null);
        }

        // 更新Xray配置并重启
        await updateUserXray(user.id);

        res.json({ success: true, message: '配置已更新，正在重启代理...' });
    } catch (error) {
        console.error('设置路由失败:', error);
        res.status(500).json({ success: false, message: error.message });
    }
});

// 获取所有节点（用户端，无需认证）
app.get('/api/user/nodes', (req, res) => {
    const nodes = db.prepare('SELECT id, name, address, protocol FROM nodes WHERE enabled = 1 ORDER BY id').all();
    res.json({ success: true, nodes });
});

// ==================== 启动服务 ====================

app.listen(PORT, '192.168.100.1', () => {
    console.log(`NexusRoute 服务已启动，监听端口 ${PORT}`);
    console.log(`用户前台: http://192.168.100.1/`);
    console.log(`管理后台: http://192.168.100.1/admin`);

    // 启动设备监控
    monitorNewDevices();
});

// 优雅关闭
process.on('SIGTERM', () => {
    console.log('收到 SIGTERM 信号，正在关闭服务...');
    db.close();
    process.exit(0);
});

process.on('SIGINT', () => {
    console.log('收到 SIGINT 信号，正在关闭服务...');
    db.close();
    process.exit(0);
});
