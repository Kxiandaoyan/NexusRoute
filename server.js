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
const DB_PATH = path.join(__dirname, 'db.sqlite');
const CONFIG_PATH = path.join(__dirname, 'config.json');
const SECRET_PATH = path.join(__dirname, '.jwt_secret');

// JWT secret: persist to file so tokens survive restarts
let JWT_SECRET;
if (fs.existsSync(SECRET_PATH)) {
    JWT_SECRET = fs.readFileSync(SECRET_PATH, 'utf8').trim();
} else {
    JWT_SECRET = crypto.randomBytes(32).toString('hex');
    fs.writeFileSync(SECRET_PATH, JWT_SECRET);
}

// 读取配置（由 install.sh 生成）
let config = { wan_if: 'eth0', lan_if: 'eth1', lan_ip: '192.168.100.1', lan_subnet: '192.168.100' };
if (fs.existsSync(CONFIG_PATH)) {
    try {
        config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
    } catch (e) {
        console.error('配置文件读取失败，使用默认值');
    }
}

// 中间件
app.use(express.json());
app.use(express.static('public'));

// 路由映射
app.get('/admin', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'admin.html'));
});

// 数据库连接
const db = new Database(DB_PATH);
db.pragma('journal_mode = WAL');

// ==================== 工具函数 ====================

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

function getNextPort() {
    const lastUser = db.prepare('SELECT MAX(xray_port) as max_port FROM users').get();
    return lastUser.max_port ? lastUser.max_port + 1 : 12345;
}

function getNextMark() {
    const lastUser = db.prepare('SELECT MAX(iptables_mark) as max_mark FROM users').get();
    return lastUser.max_mark ? lastUser.max_mark + 1 : 1;
}

// ==================== 设备监控（无审批，直连即用）====================

function monitorDevices() {
    const leasesPath = '/var/lib/misc/dnsmasq.leases';
    let isProcessing = false;

    setInterval(async () => {
        if (isProcessing) return;
        if (!fs.existsSync(leasesPath)) return;

        const content = fs.readFileSync(leasesPath, 'utf8');
        if (!content.trim()) return;

        const lines = content.trim().split('\n');

        for (const line of lines) {
            const parts = line.split(' ');
            if (parts.length < 4) continue;

            const mac = parts[1];
            const ip = parts[2];
            const hostname = parts[3];

            // 只处理本子网IP
            if (!ip.startsWith(config.lan_subnet + '.')) continue;
            // 排除网关自身
            if (ip === config.lan_ip) continue;

            // 跳过已注册设备
            if (db.prepare('SELECT id FROM users WHERE mac_address = ?').get(mac)) continue;

            isProcessing = true;
            try {
                const port = getNextPort();
                const mark = getNextMark();
                const userCount = db.prepare('SELECT COUNT(*) as count FROM users').get().count;
                const userName = `user${userCount + 1}`;

                // 创建用户（直接使用DHCP分配的IP）
                const result = db.prepare(`
                    INSERT INTO users (name, mac_address, ip_address, xray_port, iptables_mark)
                    VALUES (?, ?, ?, ?, ?)
                `).run(userName, mac, ip, port, mark);

                const userId = result.lastInsertRowid;

                // 写入静态绑定，确保IP永久不变
                const staticHostsPath = '/etc/dnsmasq.d/static-hosts.conf';
                const binding = `dhcp-host=${mac},${ip},${userName},infinite\n`;
                if (fs.existsSync(staticHostsPath)) {
                    fs.appendFileSync(staticHostsPath, binding);
                } else {
                    fs.writeFileSync(staticHostsPath, binding);
                }

                // 重载dnsmasq（不中断已有连接）
                await execCommand('systemctl reload dnsmasq || systemctl restart dnsmasq');

                // 创建Xray服务
                await createXrayService(userId);

                // 添加iptables规则
                await addIptablesRule(userId);

                console.log(`新设备接入: ${hostname || mac} -> ${userName} (${ip})`);
            } catch (error) {
                console.error(`注册设备 ${mac} 失败:`, error);
            }
            isProcessing = false;
        }
    }, 15000); // 每15秒扫描一次
}

// ==================== Xray配置生成 ====================

function generateXrayConfig(userId, nodes) {
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
    if (!user) throw new Error('用户不存在');

    const outbounds = [];

    nodes.forEach((node, index) => {
        const tag = `hop${index + 1}`;
        const outbound = { tag, protocol: node.protocol };

        switch (node.protocol) {
            case 'vmess':
                outbound.settings = {
                    vnext: [{ address: node.address, port: node.port, users: [{ id: node.uuid, alterId: node.alter_id || 0, security: node.encryption || 'auto' }] }]
                };
                break;
            case 'vless':
                outbound.settings = {
                    vnext: [{ address: node.address, port: node.port, users: [{ id: node.uuid, encryption: node.encryption || 'none', flow: node.flow || '' }] }]
                };
                break;
            case 'trojan':
                outbound.settings = {
                    servers: [{ address: node.address, port: node.port, password: node.password }]
                };
                break;
            case 'shadowsocks':
            case 'ss':
                outbound.settings = {
                    servers: [{ address: node.address, port: node.port, method: node.encryption || 'aes-256-gcm', password: node.password }]
                };
                break;
            case 'socks':
                outbound.settings = {
                    servers: [{ address: node.address, port: node.port, users: node.password ? [{ user: 'user', pass: node.password }] : [] }]
                };
                break;
        }

        outbound.streamSettings = { network: node.network || 'tcp' };

        if (node.tls === 'tls' || node.tls === 'xtls') {
            outbound.streamSettings.security = node.tls;
            const tlsSettings = { serverName: node.sni || node.address };
            if (node.alpn) tlsSettings.alpn = node.alpn.split(',');
            if (node.fingerprint) tlsSettings.fingerprint = node.fingerprint;
            outbound.streamSettings[node.tls === 'xtls' ? 'xtlsSettings' : 'tlsSettings'] = tlsSettings;
        }

        if (node.network === 'ws') {
            outbound.streamSettings.wsSettings = {
                path: node.ws_path || '/',
                headers: node.ws_host ? { Host: node.ws_host } : {}
            };
        }

        if (node.network === 'grpc') {
            outbound.streamSettings.grpcSettings = {
                serviceName: node.grpc_service_name || '',
                multiMode: node.grpc_mode === 'multi'
            };
        }

        if (index < nodes.length - 1) {
            outbound.proxySettings = { tag: `hop${index + 2}` };
        }

        outbounds.push(outbound);
    });

    return {
        log: { loglevel: 'warning' },
        dns: {
            servers: [
                { address: '1.1.1.1', skipFallback: true },
                { address: '8.8.8.8', skipFallback: true }
            ],
            queryStrategy: 'UseIP'
        },
        inbounds: [
            {
                tag: 'tproxy-in', port: user.xray_port, protocol: 'dokodemo-door',
                settings: { network: 'tcp,udp', followRedirect: true },
                streamSettings: { sockopt: { tproxy: 'tproxy', mark: user.iptables_mark } }
            },
            {
                tag: 'dns-in', port: 5353, protocol: 'dokodemo-door',
                settings: { address: '1.1.1.1', port: 53, network: 'tcp,udp' }
            }
        ],
        outbounds,
        routing: {
            domainStrategy: 'IPIfNonMatch',
            rules: [
                { type: 'field', inboundTag: ['dns-in'], outboundTag: 'hop1' },
                { type: 'field', inboundTag: ['tproxy-in'], outboundTag: 'hop1' }
            ]
        }
    };
}

// ==================== 系统服务管理 ====================

async function createXrayService(userId) {
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
    if (!user) throw new Error('用户不存在');

    const serviceName = `xray-${user.name}`;
    const configPath = `/usr/local/etc/xray/config-${user.name}.json`;

    fs.writeFileSync(`/etc/systemd/system/${serviceName}.service`,
        `[Unit]
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
`);

    await execCommand('systemctl daemon-reload');
    await execCommand(`systemctl enable ${serviceName}`);
    return serviceName;
}

async function updateUserXray(userId) {
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
    if (!user) throw new Error('用户不存在');

    const route = db.prepare('SELECT * FROM user_routes WHERE user_id = ?').get(userId);
    if (!route) {
        console.log(`用户 ${user.name} 没有配置路由`);
        return;
    }

    const nodes = [];
    [route.node1_id, route.node2_id, route.node3_id].forEach(id => {
        if (id) {
            const node = db.prepare('SELECT * FROM nodes WHERE id = ?').get(id);
            if (node) nodes.push(node);
        }
    });

    if (nodes.length === 0) throw new Error('没有有效的节点配置');

    const config = generateXrayConfig(userId, nodes);
    const configPath = `/usr/local/etc/xray/config-${user.name}.json`;
    fs.writeFileSync(configPath, JSON.stringify(config, null, 2));

    const serviceName = `xray-${user.name}`;
    await execCommand(`systemctl restart ${serviceName}`);
}

async function addIptablesRule(userId) {
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
    if (!user) throw new Error('用户不存在');

    const scriptPath = path.join(__dirname, 'iptables_rules.sh');
    if (fs.existsSync(scriptPath)) {
        await execCommand(`${scriptPath} add-user ${user.id} ${user.ip_address} ${user.mac_address} ${user.xray_port} ${user.iptables_mark}`);
    }
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

    let passwordValid = false;
    try {
        passwordValid = bcrypt.compareSync(password, admin.password_hash);
    } catch (error) {
        const simpleHash = crypto.createHash('sha256').update(password).digest('hex');
        passwordValid = admin.password_hash === simpleHash;
    }

    if (!passwordValid) {
        return res.status(401).json({ success: false, message: '用户名或密码错误' });
    }

    const token = jwt.sign({ username: admin.username }, JWT_SECRET, { expiresIn: '24h' });
    res.json({ success: true, token });
});

// 节点管理
app.get('/api/admin/nodes', authenticateToken, (req, res) => {
    const nodes = db.prepare('SELECT * FROM nodes ORDER BY hop_level, id DESC').all();
    res.json({ success: true, nodes });
});

app.post('/api/admin/nodes', authenticateToken, (req, res) => {
    const node = req.body;
    try {
        const result = db.prepare(`
            INSERT INTO nodes (
                name, protocol, address, port, uuid, alter_id, password,
                encryption, network, tls, sni, alpn, fingerprint,
                ws_path, ws_host, grpc_service_name, grpc_mode, flow, remarks, hop_level
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        `).run(
            node.name, node.protocol, node.address, node.port,
            node.uuid || null, node.alter_id || 0, node.password || null,
            node.encryption || 'auto', node.network || 'tcp',
            node.tls || 'none', node.sni || null, node.alpn || null,
            node.fingerprint || null, node.ws_path || null, node.ws_host || null,
            node.grpc_service_name || null, node.grpc_mode || 'gun',
            node.flow || null, node.remarks || null, node.hop_level || 1
        );
        res.json({ success: true, id: result.lastInsertRowid });
    } catch (error) {
        res.status(500).json({ success: false, message: error.message });
    }
});

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
                grpc_mode = ?, flow = ?, remarks = ?, hop_level = ?, enabled = ?
            WHERE id = ?
        `).run(
            node.name, node.protocol, node.address, node.port, node.uuid || null,
            node.alter_id || 0, node.password || null, node.encryption || 'auto',
            node.network || 'tcp', node.tls || 'none', node.sni || null,
            node.alpn || null, node.fingerprint || null, node.ws_path || null,
            node.ws_host || null, node.grpc_service_name || null,
            node.grpc_mode || 'gun', node.flow || null, node.remarks || null,
            node.hop_level || 1, node.enabled ? 1 : 0, id
        );
        res.json({ success: true });
    } catch (error) {
        res.status(500).json({ success: false, message: error.message });
    }
});

app.delete('/api/admin/nodes/:id', authenticateToken, (req, res) => {
    const { id } = req.params;
    try {
        db.prepare('DELETE FROM nodes WHERE id = ?').run(id);
        res.json({ success: true });
    } catch (error) {
        res.status(500).json({ success: false, message: error.message });
    }
});

// 用户列表
app.get('/api/admin/users', authenticateToken, (req, res) => {
    const users = db.prepare('SELECT * FROM users ORDER BY id').all();
    res.json({ success: true, users });
});

// 全局重启所有Xray实例
app.post('/api/admin/restart-all', authenticateToken, async (req, res) => {
    try {
        const users = db.prepare('SELECT * FROM users WHERE enabled = 1').all();
        for (const user of users) {
            try {
                await execCommand(`systemctl restart xray-${user.name}`);
            } catch (error) {
                console.error(`重启 xray-${user.name} 失败:`, error);
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
            status: 'configuring',
            message: '设备正在配置中，请稍候...'
        });
    }

    const serviceName = `xray-${user.name}`;
    exec(`systemctl is-active ${serviceName}`, (error, stdout) => {
        const isActive = stdout.trim() === 'active';

        const route = db.prepare('SELECT * FROM user_routes WHERE user_id = ?').get(user.id);
        let currentRoute = null;
        let exitIP = null;

        if (route) {
            const nodes = {};
            ['node1_id', 'node2_id', 'node3_id'].forEach((key, i) => {
                if (route[key]) {
                    const node = db.prepare('SELECT * FROM nodes WHERE id = ?').get(route[key]);
                    if (node) {
                        nodes[`node${i + 1}`] = node.name;
                        exitIP = node.address;
                    }
                }
            });
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
            return res.status(403).json({ success: false, message: '设备尚未就绪，请稍候' });
        }

        const existing = db.prepare('SELECT id FROM user_routes WHERE user_id = ?').get(user.id);
        if (existing) {
            db.prepare(`
                UPDATE user_routes SET node1_id = ?, node2_id = ?, node3_id = ?, updated_at = CURRENT_TIMESTAMP
                WHERE user_id = ?
            `).run(node1_id, node2_id || null, node3_id || null, user.id);
        } else {
            db.prepare(`
                INSERT INTO user_routes (user_id, node1_id, node2_id, node3_id) VALUES (?, ?, ?, ?)
            `).run(user.id, node1_id, node2_id || null, node3_id || null);
        }

        await updateUserXray(user.id);
        res.json({ success: true, message: '配置已更新，正在重启代理...' });
    } catch (error) {
        console.error('设置路由失败:', error);
        res.status(500).json({ success: false, message: error.message });
    }
});

// 获取节点列表（用户端）
app.get('/api/user/nodes', (req, res) => {
    const { hop_level } = req.query;
    let query = 'SELECT id, name, address, protocol, hop_level FROM nodes WHERE enabled = 1';
    let params = [];

    if (hop_level) {
        query += ' AND hop_level = ?';
        params.push(parseInt(hop_level));
    }

    query += ' ORDER BY hop_level, id';
    const nodes = db.prepare(query).all(...params);
    res.json({ success: true, nodes });
});

// ==================== 启动服务 ====================

app.listen(PORT, config.lan_ip, () => {
    console.log(`NexusRoute 服务已启动，监听 ${config.lan_ip}:${PORT}`);
    console.log(`用户前台: http://${config.lan_ip}/`);
    console.log(`管理后台: http://${config.lan_ip}/admin`);
    console.log(`LAN接口: ${config.lan_if} | WAN接口: ${config.wan_if}`);

    monitorDevices();
});

process.on('SIGTERM', () => {
    console.log('收到 SIGTERM 信号，正在关闭...');
    db.close();
    process.exit(0);
});

process.on('SIGINT', () => {
    console.log('收到 SIGINT 信号，正在关闭...');
    db.close();
    process.exit(0);
});
