#!/usr/bin/env node

const bcrypt = require('bcryptjs');
const crypto = require('crypto');
const Database = require('better-sqlite3');
const readline = require('readline');

const DB_PATH = '/opt/nexusroute/db.sqlite';

const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
});

function question(prompt) {
    return new Promise((resolve) => {
        rl.question(prompt, resolve);
    });
}

async function main() {
    console.log('=== NexusRoute Admin Password Diagnostic Tool ===\n');

    // 打开数据库
    const db = new Database(DB_PATH);

    // 查询当前管理员
    const admin = db.prepare('SELECT * FROM admins WHERE username = ?').get('admin');

    if (!admin) {
        console.log('❌ 数据库中没有找到 admin 用户！');
        console.log('创建默认 admin 用户...\n');

        const password = await question('请输入新密码: ');
        const passwordHash = bcrypt.hashSync(password, 10);

        db.prepare('INSERT INTO admins (username, password_hash) VALUES (?, ?)').run('admin', passwordHash);
        console.log('✅ admin 用户已创建');
        console.log(`用户名: admin`);
        console.log(`密码: ${password}`);
        rl.close();
        db.close();
        return;
    }

    console.log('✅ 找到 admin 用户');
    console.log(`用户名: ${admin.username}`);
    console.log(`密码哈希: ${admin.password_hash.substring(0, 20)}...`);
    console.log(`哈希长度: ${admin.password_hash.length}\n`);

    // 检测哈希类型
    let hashType = 'unknown';
    if (admin.password_hash.startsWith('$2a$') || admin.password_hash.startsWith('$2b$')) {
        hashType = 'bcrypt';
    } else if (admin.password_hash.length === 64) {
        hashType = 'sha256';
    }

    console.log(`密码哈希类型: ${hashType}\n`);

    // 测试密码
    const testPassword = await question('请输入要测试的密码: ');

    console.log('\n测试密码验证...');

    // 测试 bcrypt
    let bcryptValid = false;
    try {
        bcryptValid = bcrypt.compareSync(testPassword, admin.password_hash);
        console.log(`Bcrypt 验证: ${bcryptValid ? '✅ 通过' : '❌ 失败'}`);
    } catch (error) {
        console.log(`Bcrypt 验证: ❌ 错误 (${error.message})`);
    }

    // 测试简单哈希
    const simpleHash = crypto.createHash('sha256').update(testPassword).digest('hex');
    const simpleHashValid = admin.password_hash === simpleHash;
    console.log(`SHA256 验证: ${simpleHashValid ? '✅ 通过' : '❌ 失败'}`);

    if (!bcryptValid && !simpleHashValid) {
        console.log('\n❌ 密码验证失败！');
        const reset = await question('\n是否重置密码？(y/n): ');

        if (reset.toLowerCase() === 'y') {
            const newPassword = await question('请输入新密码: ');
            const newPasswordHash = bcrypt.hashSync(newPassword, 10);

            db.prepare('UPDATE admins SET password_hash = ? WHERE username = ?').run(newPasswordHash, 'admin');

            console.log('\n✅ 密码已重置');
            console.log(`用户名: admin`);
            console.log(`新密码: ${newPassword}`);
            console.log(`新哈希: ${newPasswordHash.substring(0, 20)}...`);
        }
    } else {
        console.log('\n✅ 密码验证成功！');
    }

    rl.close();
    db.close();
}

main().catch(error => {
    console.error('错误:', error);
    process.exit(1);
});
