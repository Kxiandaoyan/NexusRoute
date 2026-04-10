#!/usr/bin/env node

// NexusRoute - 待审批设备诊断工具
// 用于检查待审批设备功能是否正常

const Database = require('better-sqlite3');
const fs = require('fs');
const path = require('path');

const DB_PATH = '/opt/nexusroute/db.sqlite';
const LEASES_PATH = '/var/lib/misc/dnsmasq.leases';

console.log('=== NexusRoute 待审批设备诊断工具 ===\n');

// 1. 检查数据库文件
console.log('1. 检查数据库文件...');
if (!fs.existsSync(DB_PATH)) {
    console.error('❌ 数据库文件不存在:', DB_PATH);
    process.exit(1);
}
console.log('✅ 数据库文件存在');

// 2. 检查数据库表
console.log('\n2. 检查数据库表...');
const db = new Database(DB_PATH);

try {
    const tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all();
    console.log('数据库中的表:', tables.map(t => t.name).join(', '));

    const hasPendingDevices = tables.some(t => t.name === 'pending_devices');
    if (!hasPendingDevices) {
        console.error('❌ pending_devices 表不存在！');
        console.log('\n修复方法：');
        console.log('sudo sqlite3 /opt/nexusroute/db.sqlite <<EOF');
        console.log('CREATE TABLE IF NOT EXISTS pending_devices (');
        console.log('  id INTEGER PRIMARY KEY AUTOINCREMENT,');
        console.log('  mac_address TEXT UNIQUE NOT NULL,');
        console.log('  first_seen DATETIME DEFAULT CURRENT_TIMESTAMP,');
        console.log('  last_seen DATETIME DEFAULT CURRENT_TIMESTAMP,');
        console.log('  hostname TEXT,');
        console.log('  status TEXT DEFAULT \'pending\'');
        console.log(');');
        console.log('EOF');
        process.exit(1);
    }
    console.log('✅ pending_devices 表存在');
} catch (error) {
    console.error('❌ 检查数据库表失败:', error.message);
    process.exit(1);
}

// 3. 检查表结构
console.log('\n3. 检查表结构...');
try {
    const columns = db.prepare('PRAGMA table_info(pending_devices)').all();
    console.log('pending_devices 表字段:');
    columns.forEach(col => {
        console.log(`  - ${col.name} (${col.type})`);
    });
} catch (error) {
    console.error('❌ 检查表结构失败:', error.message);
}

// 4. 查询待审批设备
console.log('\n4. 查询待审批设备...');
try {
    const devices = db.prepare("SELECT * FROM pending_devices WHERE status = 'pending'").all();
    console.log(`找到 ${devices.length} 个待审批设备:`);
    if (devices.length > 0) {
        devices.forEach(device => {
            console.log(`  - MAC: ${device.mac_address}, 主机名: ${device.hostname || 'Unknown'}, 首次发现: ${device.first_seen}`);
        });
    } else {
        console.log('  (无待审批设备)');
    }
} catch (error) {
    console.error('❌ 查询待审批设备失败:', error.message);
}

// 5. 检查 dnsmasq leases 文件
console.log('\n5. 检查 dnsmasq leases 文件...');
if (!fs.existsSync(LEASES_PATH)) {
    console.error('❌ dnsmasq leases 文件不存在:', LEASES_PATH);
    console.log('可能原因：');
    console.log('  - dnsmasq 服务未启动');
    console.log('  - 没有设备连接到网关');
    console.log('\n检查方法：');
    console.log('  sudo systemctl status dnsmasq');
} else {
    console.log('✅ dnsmasq leases 文件存在');

    try {
        const content = fs.readFileSync(LEASES_PATH, 'utf8');
        const lines = content.trim().split('\n').filter(l => l);
        console.log(`当前有 ${lines.length} 个 DHCP 租约:`);

        lines.forEach(line => {
            const parts = line.split(' ');
            if (parts.length >= 5) {
                const [timestamp, mac, ip, hostname] = [parts[0], parts[1], parts[2], parts[3]];
                const ipNum = parseInt(ip.split('.')[3]);
                const isTemp = ipNum >= 50 && ipNum <= 99;
                console.log(`  - MAC: ${mac}, IP: ${ip}, 主机名: ${hostname}, ${isTemp ? '临时IP ⚠️' : '永久IP ✅'}`);
            }
        });
    } catch (error) {
        console.error('❌ 读取 leases 文件失败:', error.message);
    }
}

// 6. 检查已授权用户
console.log('\n6. 检查已授权用户...');
try {
    const users = db.prepare('SELECT * FROM users').all();
    console.log(`已授权用户数: ${users.length}`);
    if (users.length > 0) {
        users.forEach(user => {
            console.log(`  - ${user.name}: IP=${user.ip_address}, MAC=${user.mac_address}`);
        });
    }
} catch (error) {
    console.error('❌ 查询用户失败:', error.message);
}

// 7. 检查服务状态
console.log('\n7. 检查服务状态...');
const { execSync } = require('child_process');
try {
    const status = execSync('systemctl is-active nexusroute', { encoding: 'utf8' }).trim();
    if (status === 'active') {
        console.log('✅ NexusRoute 服务运行中');
    } else {
        console.log('❌ NexusRoute 服务未运行:', status);
    }
} catch (error) {
    console.log('❌ NexusRoute 服务未运行');
}

try {
    const status = execSync('systemctl is-active dnsmasq', { encoding: 'utf8' }).trim();
    if (status === 'active') {
        console.log('✅ dnsmasq 服务运行中');
    } else {
        console.log('❌ dnsmasq 服务未运行:', status);
    }
} catch (error) {
    console.log('❌ dnsmasq 服务未运行');
}

console.log('\n=== 诊断完成 ===');
db.close();
